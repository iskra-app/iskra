import Foundation
import Observation
import MatrixRustSDK

/// The messages a room has pinned, as a conversation of their own.
///
/// A second timeline over the same room. The SDK offers this directly —
/// `TimelineFocus.pinnedEvents` — and that is worth taking rather than building by hand: the
/// alternative is holding a list of event IDs and going and fetching each one, which is a
/// cache to keep in step, a set of requests to batch, and a redaction to notice when somebody
/// deletes a message that was pinned. The SDK already does all of it.
///
/// It is deliberately *not* opened with the room. Most rooms have nothing pinned, and a
/// timeline nobody is looking at is still a subscription the SDK has to feed. `TimelineStore`
/// builds one on demand, when there is something to show.
@MainActor
@Observable
public final class PinnedStore {
    /// Oldest first, exactly as the timeline delivers them — so the *last* is the most
    /// recently pinned, which is the one the strip at the top of the room shows.
    public private(set) var messages: [Message] = []

    /// True once the SDK has answered, including when the answer is "nothing". Same reason as
    /// `TimelineStore.hasLoaded`: an empty list and one that has not arrived are the same empty
    /// array, and only one of them should say "nothing pinned".
    public private(set) var hasLoaded = false

    private let room: Room
    private let ownUserID: String

    private var timeline: Timeline?
    private var listenerHandle: TaskHandle?
    private var items: [TimelineItem] = []
    /// `items`, already mapped. See `TimelineMapper.Memo`.
    @ObservationIgnored private let mapped = TimelineMapper.Memo()

    /// The store counts its openings, exactly as `TimelineStore` does and for the same reason: a
    /// `Task` already inside an SDK await does not stop because `stop()` cancelled a handle, and
    /// when it comes back it must not write into a store that has moved on. `stop()` bumps the
    /// number; anything that spans an await takes it on the way in and checks it before writing.
    private var generation = 0

    /// The opening in flight, so a second caller waits for it instead of starting a rival one.
    /// Without it, two `start()`s racing through the awaits below would each build a timeline and
    /// register a listener, and the second `addListener` would overwrite the handle to the first —
    /// leaking that subscription for the life of the store. Same fix as `TimelineStore.start()`.
    private var opening: Task<Void, Never>?

    /// The one ordered road from the Rust callback thread to this actor. The SDK's diffs are
    /// positional — `insert(at:)`, `set(at:)`, `remove(at:)` — so a batch means nothing except
    /// applied against the exact list the batch before it produced, and separately created
    /// `Task { @MainActor }`s have no order between them on an actor. `TimelineStore` learned this
    /// the hard way (see its `open()`); this second timeline had been left answering each callback
    /// in its own task, free to run out of order and quietly shuffle the pinned strip.
    private var diffContinuation: AsyncStream<UnsafeTransfer<[TimelineDiff]>>.Continuation?
    private var diffTask: Task<Void, Never>?

    /// Whether the list is being read again after the diffs stopped making sense — see `resync()`.
    /// One fault can arrive as a batch of twenty impossible indices; it is still one fault.
    private var isResyncing = false

    init(room: Room, ownUserID: String) {
        self.room = room
        self.ownUserID = ownUserID
    }

    public func start() async {
        // Somebody is already opening this. Wait for them and stop — the timeline they opened is
        // the one we wanted. Turning up second is ordinary: `TimelineStore.start()`'s tail starts
        // us, and so does the view coming back onto the screen.
        if let opening {
            await opening.value
            return
        }

        guard timeline == nil else { return }

        let generation = self.generation
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.open(generation: generation)
        }
        opening = task

        defer {
            // Only if it is still ours. A `stop()` mid-open abandons this task and clears the
            // field, and a fresh `start()` may already have put its own there — clearing it blindly
            // would leave that one unreachable. See `TimelineStore.start()`.
            if generation == self.generation { opening = nil }
        }

        await task.value
    }

    private func open(generation: Int) async {
        let configuration = TimelineConfiguration(focus: .pinnedEvents,
                                                  filter: .all,
                                                  internalIdPrefix: "pinned",
                                                  dateDividerMode: .daily,
                                                  // Nothing here shows a read tick, and tracking
                                                  // receipts is the SDK's own warning about
                                                  // cost — so it is off.
                                                  trackReadReceipts: .disabled,
                                                  reportUtds: false)

        guard let timeline = try? await room.timelineWithConfiguration(configuration: configuration) else {
            guard generation == self.generation else { return }
            hasLoaded = true
            return
        }

        // Left while the timeline was being built — the reader closed the pinned strip, or the
        // account was signed out. Nothing more of this opening's is ours to keep.
        guard generation == self.generation else { return }
        self.timeline = timeline

        // One stream, one consumer, in the order the SDK spoke — the same queue `TimelineStore`
        // runs its diffs down (see its `open()`), and for the same reason. The callback runs on a
        // Rust thread and holds no `self`: it only yields, and the drain task below is the one
        // thing applying what it yields.
        let (diffs, continuation) = AsyncStream<UnsafeTransfer<[TimelineDiff]>>.makeStream()
        diffContinuation = continuation

        let listener = PinnedItemsListener { batch in
            continuation.yield(UnsafeTransfer(value: batch))
        }

        diffTask = Task { @MainActor [weak self] in
            for await batch in diffs {
                self?.apply(diffs: batch.value)
            }
        }

        listenerHandle = await timeline.addListener(listener: listener)

        // Stopped while the listener was being registered. The subscription just returned is not
        // ours to keep — `stop()` has already run and had nothing to cancel — so it comes down here
        // rather than feeding a store that has moved on.
        guard generation == self.generation else {
            listenerHandle?.cancel()
            listenerHandle = nil
            return
        }

        // Unlike a live timeline, this one does *not* have to be paginated into existence: a
        // pinned timeline is the pinned events, all of them, and the SDK hands them over as its
        // first diff. There is no history behind it to fetch.
        hasLoaded = true
    }

    /// Puts the pinned timeline down, and — unlike the version this replaces — leaves it in a state
    /// it can be picked up from again.
    ///
    /// It used to cancel the listener and stop there, leaving `timeline` set. `start()` opens with
    /// `guard timeline == nil else { return }`, so a store that had been stopped could never be
    /// started: no listener, a timeline it would not replace, `messages` frozen at whatever was in
    /// them, and no way back. That is the identical dead end `TimelineStore.stop()` carries a long
    /// comment about having fixed, and it sat here untouched — undetected only because *nothing
    /// ever called this*. It was a mine waiting for the first person to tidy up after themselves.
    public func stop() {
        // A number, not a cancel, is what reaches a `start()` already sitting in an SDK await and
        // tells it the timeline it is opening is no longer wanted. See `generation`.
        generation += 1
        opening = nil

        listenerHandle?.cancel()
        listenerHandle = nil

        // The queue the diffs came down, and the one task draining it — finished before `items` is
        // emptied below, so nothing can apply a diff from the timeline that is going to the list
        // that replaces it.
        diffContinuation?.finish()
        diffContinuation = nil
        diffTask?.cancel()
        diffTask = nil

        timeline = nil
        // The SDK's items belonged to the timeline that has just gone. A fresh listener opens with
        // an empty reset and repopulates from scratch, and leaving these here would have the next
        // `apply` computing diffs against a timeline that no longer exists.
        items = []
        mapped.removeAll()
        hasLoaded = false
    }

    /// Takes a message off the pinned list. The only thing this screen can *do*, and the reason
    /// it holds the room at all.
    public func unpin(messageID: String) async {
        guard let timeline else { return }
        _ = try? await timeline.unpinEvent(eventId: messageID)
    }

    private func apply(diffs: [TimelineDiff]) {
        // The same arithmetic the room's own timeline uses, and — until this — *not* the same
        // arithmetic. This store had its own copy of the twelve cases, and its copy was the old
        // one: it clamped an out-of-range insert to the end of the list and swallowed an
        // out-of-range `set` and `remove` entirely. `TimelineStore` carries a long comment about
        // why that is the wrong answer, and it was written while this file went on doing it. The
        // strip at the top of the room would simply have been wrong, in the same untraceable way,
        // and rather more quietly, since nobody looks hard at four pinned messages.
        switch items.apply(diffs.map(\.asListDiff)) {
        case let .desynced(what):
            Log.rooms.error("The pinned list is out of step with the SDK: \(what, privacy: .public). Reading it again.")
            Task { await resync() }
            return

        case .applied:
            break
        }

        // Only the messages. A pinned timeline carries date dividers like any other, and a
        // list of four pinned messages is not a conversation that needs its days marked.
        messages = TimelineMapper.rows(from: items, ownUserID: ownUserID, memo: mapped).compactMap(\.message)
    }

    /// What we hold is no longer what the SDK is talking about, so it is asked again.
    ///
    /// Stopping and starting is the whole of it, for the same reason it is in `TimelineStore`: a
    /// fresh listener opens with a `reset`, which is the SDK's own account of what it is holding —
    /// the very thing that has been lost. There is nothing to preserve here and no reader to keep
    /// their place for; a pinned list is short and arrives whole.
    private func resync() async {
        // A desync is worth reading again only while there is still a timeline to read. If the store
        // was stopped out from under this — a sign-out three screens away, between the diff that
        // desynced and this task getting to run — `timeline` is already nil, and starting a fresh
        // one now would reopen a listener over a store that `logout()` is about to delete from disk.
        guard !isResyncing, timeline != nil else { return }
        isResyncing = true
        defer { isResyncing = false }

        stop()
        await start()
    }
}

private final class PinnedItemsListener: TimelineListener {
    private let onDiff: @Sendable ([TimelineDiff]) -> Void

    init(onDiff: @escaping @Sendable ([TimelineDiff]) -> Void) {
        self.onDiff = onDiff
    }

    func onUpdate(diff: [TimelineDiff]) {
        onDiff(diff)
    }
}
