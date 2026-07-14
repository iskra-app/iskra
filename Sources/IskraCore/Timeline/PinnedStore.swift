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

    init(room: Room, ownUserID: String) {
        self.room = room
        self.ownUserID = ownUserID
    }

    public func start() async {
        guard timeline == nil else { return }

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
            hasLoaded = true
            return
        }
        self.timeline = timeline

        let listener = PinnedItemsListener { [weak self] diffs in
            let transfer = UnsafeTransfer(value: diffs)
            Task { @MainActor [weak self] in
                self?.apply(diffs: transfer.value)
            }
        }
        listenerHandle = await timeline.addListener(listener: listener)

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
        listenerHandle?.cancel()
        listenerHandle = nil

        timeline = nil
        // The SDK's items belonged to the timeline that has just gone. A fresh listener opens with
        // an empty reset and repopulates from scratch, and leaving these here would have the next
        // `apply` computing diffs against a timeline that no longer exists.
        items = []
        hasLoaded = false
    }

    /// Takes a message off the pinned list. The only thing this screen can *do*, and the reason
    /// it holds the room at all.
    public func unpin(messageID: String) async {
        guard let timeline else { return }
        _ = try? await timeline.unpinEvent(eventId: messageID)
    }

    private func apply(diffs: [TimelineDiff]) {
        for diff in diffs {
            switch diff {
            case let .append(values): items.append(contentsOf: values)
            case .clear: items.removeAll()
            case let .pushFront(value): items.insert(value, at: 0)
            case let .pushBack(value): items.append(value)
            case .popFront: if !items.isEmpty { items.removeFirst() }
            case .popBack: if !items.isEmpty { items.removeLast() }
            case let .insert(index, value): items.insert(value, at: min(Int(index), items.count))
            case let .set(index, value):
                let i = Int(index)
                if items.indices.contains(i) { items[i] = value }
            case let .remove(index):
                let i = Int(index)
                if items.indices.contains(i) { items.remove(at: i) }
            case let .truncate(length):
                let n = Int(length)
                if n < items.count { items.removeSubrange(n...) }
            case let .reset(values): items = values
            }
        }

        // Only the messages. A pinned timeline carries date dividers like any other, and a
        // list of four pinned messages is not a conversation that needs its days marked.
        messages = TimelineMapper.rows(from: items, ownUserID: ownUserID).compactMap(\.message)
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
