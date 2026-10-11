import Foundation
import Observation
import MatrixRustSDK

/// Carries a non-`Sendable` SDK value across the hop from a Rust callback thread to
/// the main actor.
///
/// The SDK's own handle types (`Room`, `Client`, …) are already `@unchecked
/// Sendable` because the Rust side is thread-safe; it is only the generated *enums*
/// wrapping them that lack the annotation. This box says that out loud instead of
/// silently weakening the whole type.
struct UnsafeTransfer<T>: @unchecked Sendable {
    let value: T
}

/// The conversation list, kept live by the SDK's sync loop.
///
/// The SDK hands us an ordered list of rooms as a stream of diffs (insert at 3,
/// move to front, …) rather than whole snapshots, because on a busy account
/// resending the whole list on every change would be wasteful. We apply those diffs
/// to an ordered array of room handles, then project that into value-type summaries
/// that SwiftUI can diff cheaply.
@MainActor
@Observable
public final class RoomListStore {
    /// What the UI renders. Ordered by recency (pinned rooms first), as the server sorts it.
    /// Archived rooms are held back — they live in `archivedRooms` and on the archive screen.
    public private(set) var rooms: [RoomSummary] = []

    /// The archived rooms — the ones the user has swept out of the main list. This is the Matrix
    /// `m.lowpriority` tag; the rooms are still fully joined, with their history intact, they are
    /// just kept off the main list until the user goes looking for them.
    ///
    /// Filtered out here in the projection rather than at the SDK filter, on purpose: filtering
    /// `.lowPriority` out of the room list would drop these rooms from the diff stream altogether,
    /// and then there would be nothing left to *show* on the archive screen. One stream, split in
    /// two at the end, keeps both lists reading from the same source of truth.
    public private(set) var archivedRooms: [RoomSummary] = []

    /// True until the first batch of rooms arrives, so the UI can say something
    /// friendlier than showing an empty list.
    public private(set) var isLoadingInitialRooms = true

    /// The rooms where somebody other than the user is writing right now — which the list says
    /// in place of the last message, the way the header of the room says it.
    ///
    /// A set of IDs rather than a field on `RoomSummary`, because typing comes and goes a dozen
    /// times a minute and a summary is rebuilt from `roomInfo()` for every room in the list: the
    /// two must not be tied together, or every keystroke on the far side of a chat would rebuild
    /// the whole list.
    public private(set) var typingRoomIDs: Set<String> = []

    /// One subscription per room in the list. The notices themselves arrive with sliding sync
    /// whether anybody listens or not; this is only the listening.
    private var typingHandles: [String: TaskHandle] = [:]

    /// The app cannot reach the homeserver, and everything on the screen is what was on the device
    /// already. Written by `syncStateChanged`, which is where the app finds this out.
    ///
    /// It has to be *said* on screen. The conversations are all still there when the network goes,
    /// and a list that looks exactly as it did a minute ago while quietly receiving nothing is the
    /// most confusing thing the app can do: the messages people are waiting for simply never arrive,
    /// and nothing anywhere explains why.
    public private(set) var isOffline = false

    /// An invitation that would not be accepted or declined. Reported the same way `RoomDetailsStore`
    /// reports a refusal — as a field the screen puts in an alert — rather than thrown, because the
    /// press that caused it happened in a *row of a list*, and there is no call stack there to catch
    /// anything on.
    public var failure: RoomActionFailure?

    /// How long the sync service gets to shut down before it is left to its own devices. Short:
    /// nobody is waiting on the answer, they are waiting on the sign-out this is in the way of.
    private static let stopTimeout: Duration = .seconds(5)

    private let client: Client
    /// Who we are, for the rows that describe a room by whoever else is in it. See `init`.
    private let ownUserID: String
    private var syncService: SyncService?
    private var roomList: RoomList?

    /// The one ordered road from the Rust callback thread to this actor — see `start()`.
    private var entriesContinuation: AsyncStream<UnsafeTransfer<[RoomListEntriesUpdate]>>.Continuation?
    private var entriesTask: Task<Void, Never>?

    /// Whether the list is being asked for again after the diffs stopped making sense — see
    /// `desynced`. One fault can arrive as a batch of twenty impossible indices; it is still one.
    private var isResyncing = false

    /// Every room you have not left. Named once, because it is set twice — when the list is built,
    /// and again when it has to be asked for from scratch — and two spellings of the same filter
    /// would be two lists that differ only when somebody forgets to change both.
    private static let filter: RoomListEntriesDynamicFilterKind = .all(filters: [.nonLeft])

    /// The sync service, for the one caller outside this store that has to have it: clearing the
    /// cache takes the service down and brings it back up, and this is the only place one exists.
    /// Internal, and read-only — the SDK object still does not leave `IskraCore`.
    var currentSyncService: SyncService? { syncService }
    private var entriesResult: RoomListEntriesWithDynamicAdaptersResult?

    /// Told when the network comes or goes, so that the rooms that are *open* can hear about it.
    ///
    /// Internal, and a closure rather than a delegate, because it has exactly one subscriber:
    /// `UserSession`, which knows which timelines are on screen. This store does not — and should
    /// not — know that timelines exist.
    var onConnectivityChange: ((Bool) async -> Void)?

    /// Keeps the previews honest about messages that have not left yet — see `start()`.
    private var sendQueueHandle: TaskHandle?

    /// The SDK telling us a room's send queue has stopped itself — see `sendQueueStopped()`.
    private var sendQueueErrorHandle: TaskHandle?

    /// The restart waiting out its pause, if one is. One for all rooms: `enableAllSendQueues` is
    /// the call, and two rooms failing in the same second are one network having a bad moment.
    private var sendQueueRestart: Task<Void, Never>?
    private var sendQueueRecovery = SendQueueRecovery()

    /// The thing that actually keeps the diff stream alive.
    ///
    /// `entriesWithDynamicAdapters` hands back a result, and the result's `entriesStream()` is the
    /// `TaskHandle` for the stream itself. Nobody was ever taking it, so nobody was ever cancelling
    /// it: `stop()` shut the sync service down and left the diffs coming. See `stop()` for what
    /// that cost.
    private var entriesHandle: TaskHandle?

    /// Set by `stop()`. A diff already on its way from the Rust side arrives *after* we have shut
    /// down, and it must not be acted on — see `stop()`.
    private var hasStopped = false

    /// The sync service saying how it is getting on. Kept because dropping it unsubscribes.
    private var syncStateHandle: TaskHandle?

    /// True while a restart is being waited out, so that a burst of `.error` states — which is what
    /// losing the network actually looks like — schedules one restart rather than twenty.
    private var isRestartingSync = false

    /// Whether the app has put sync down on purpose. Distinct from `hasStopped`, and the difference
    /// is the whole reason both exist: `hasStopped` means this store is finished and must never act
    /// again, and this means it is asleep and will be woken. Without it, pausing for the background
    /// would look exactly like a sync failure to the observer below, which would dutifully restart
    /// the thing that had just been deliberately stopped.
    private var isPaused = false

    /// The room handles, in the order the SDK says they should appear.
    private var orderedRooms: [Room] = []

    /// Coalesces bursts of diffs into one summary rebuild. During initial sync the
    /// SDK can emit many updates in quick succession and rebuilding on each one
    /// would mean a stampede of `roomInfo()` calls.
    private var rebuildTask: Task<Void, Never>?

    /// The subscription to a chat being renamed on this device. Held because dropping it
    /// unsubscribes, and released in `stop()` with everything else.
    private var localNameObserver: LocalNameSubscription?

    public init(client: Client) {
        self.client = client
        // Fixed for the life of the client, and needed on every row: a personal chat takes its
        // name and its face from the *other* person, and telling them apart takes knowing which
        // one is us. Resolved once here rather than asked of the SDK per room per rebuild.
        self.ownUserID = (try? client.userId()) ?? ""
    }

    /// Starts syncing and streaming room updates. Safe to call again after `stop()`.
    public func start() async throws {
        guard syncService == nil else { return }
        hasStopped = false
        // Every `await` below is a moment `stop()` can run in — a sign-out, an account switch, the
        // bridge changed in settings — and `stop()` can only tear down what already exists. This
        // used to carry on regardless and end in `service.start()`: a sync loop for a session that
        // had been closed, never stopped, on a client that might go straight to the homeserver
        // after the user had asked for the bridge. So each step asks whether it is still wanted.
        let started = generation
        do {
            try await startSteps(started)
        } catch {
            // Half-built and failed: tear down what exists, so the next `start()` can try again
            // instead of finding `syncService` set and returning, for ever, having synced nothing.
            if started == generation { await stop() }
            throw error
        }
    }

    private func isStillWanted(_ started: Int) -> Bool {
        !hasStopped && started == generation
    }

    private func startSteps(_ started: Int) async throws {
        // A chat renamed on this device: nothing syncs, so no diff will ever arrive to say the row
        // has changed. The rebuild is the list's own ordinary way of recomputing every summary, and
        // it is debounced, so asking for one here costs a rename exactly one pass over the rooms.
        // See `LocalNames`.
        localNameObserver = LocalNames.observe { [weak self] _ in
            self?.scheduleRebuild()
        }

        // Which rooms are silenced, and then whenever that changes.
        //
        // The same problem as a rename, and it is worth spelling out because it does not look like
        // one: muting a chat writes a *push rule*, not room state, so nothing about the room
        // changes and no room-list diff is ever emitted. Without this the badge stayed the accent
        // until some unrelated message arrived and happened to rebuild the row. The delegate is the
        // SDK's own "the notification settings moved" — it says nothing about which rule, which is
        // all this needs: the set is read again and the list recomputed.
        await watchMuting()
        guard isStillWanted(started) else { return }

        // Offline mode is the SDK's own answer to a network that has gone away, and without it the
        // sync loop treats one as a failure: it reports `.error`, stops, and waits to be restarted.
        // The rooms are all still there in the encrypted store — the app simply had no way to keep
        // serving them while it was busy calling the absence of a network an error.
        //
        // With it, sync reports `.offline` instead and stays up, reading from the store until the
        // network comes back. `syncStateChanged` below already treats `.offline` as a state to sit
        // in rather than restart out of, which is exactly right: there is nothing to restart into.
        let service = try await client.syncService().withOfflineMode().finish()
        // Not kept if nobody wants it any more: `stop()` has already been and gone, and would never
        // know to stop this one.
        guard isStillWanted(started) else { return }
        syncService = service

        let list = try await service.roomListService().allRooms()
        guard isStillWanted(started) else { return }
        roomList = list

        // One ordered queue, for the same reason as the timeline's — see `TimelineStore.open()`,
        // where this bug was actually caught. A room-list diff is positional too (`insert(3, room)`,
        // `remove(1)`), and a `Task { @MainActor }` per callback lets two batches from the SDK be
        // applied in the order the executor felt like rather than the order they were sent. Nothing
        // in this store was ever reported wrong, and that is not evidence: initial sync is a burst
        // of batches, and a list that comes out with one conversation in the wrong place looks
        // exactly like a list that is sorted by something you have misremembered.
        let (diffs, continuation) = AsyncStream<UnsafeTransfer<[RoomListEntriesUpdate]>>.makeStream()
        entriesContinuation = continuation

        let listener = EntriesListener { batch in
            continuation.yield(UnsafeTransfer(value: batch))
        }

        entriesTask = Task { @MainActor [weak self] in
            for await batch in diffs {
                self?.apply(diffs: batch.value)
            }
        }

        let result = try await list.entriesWithDynamicAdapters(pageSize: 100, listener: listener)
        guard isStillWanted(started) else {
            continuation.finish()
            return
        }
        entriesResult = result
        entriesHandle = result.entriesStream()
        // A room you have walked out of is still a room the SDK knows about, and with no filter
        // at all it keeps its place in the list: the chat sat there after "Leave", could be
        // opened, and read — which reads as the app not having done what it said it did. It had:
        // the membership really was gone on the server, and the list was simply showing every
        // room in the store rather than every room you are *in*. `nonLeft` is the SDK's own name
        // for that distinction, and an invitation you have not answered yet is still not left,
        // so this hides nothing the user has still to decide about.
        _ = result.controller().setFilter(kind: Self.filter)

        // The second source of truth, and the one the list used to be missing.
        //
        // The room list emits a diff when the *server* says something changed. A message
        // the user has just written has not reached the server — it is sitting in the send
        // queue — so it moves nothing in that list, no diff arrives, and the previews are
        // never rebuilt. The room's own `latestEvent()` knew about it all along (it
        // reports a `.local` event, which `rebuildSummaries` already reads); nothing was
        // ever asking it again. The result was a chat list that showed the last message
        // that *landed* while the one the user actually sent was nowhere on the screen —
        // worst of all for a message that failed, where the list quietly agreed with the
        // server that nothing had happened.
        //
        // The send queue is what knows. Every enqueue, send and failure comes through
        // here, and each one is a reason to look again.
        let sendQueueListener = SendQueueListener { [weak self] in
            Task { @MainActor [weak self] in
                self?.scheduleRebuild()
            }
        }
        let queueHandle = try await client.subscribeToSendQueueUpdates(listener: sendQueueListener)
        guard isStillWanted(started) else {
            queueHandle.cancel()
            return
        }
        sendQueueHandle = queueHandle

        // And the queues that stop themselves. A send that fails for a reason that may pass — a
        // dropped request, a server timing out — disables that room's queue, and the SDK waits to be
        // told to carry on. See `SendQueueRecovery`, which decides when.
        sendQueueErrorHandle = client.subscribeToSendQueueStatus(listener: SendQueueErrorListener { [weak self] in
            Task { @MainActor [weak self] in
                self?.sendQueueStopped()
            }
        })

        // Nobody was listening to this, and the sync loop is the one thing in the app that *cannot*
        // be allowed to fail quietly. It stops on a network error like any other network client —
        // and then simply stays stopped. No diff ever arrives again, the room list freezes on
        // whatever it last held, and there is nothing on the screen to say so: the conversations are
        // all there, they are just from some minutes ago and will never be from any later. The only
        // cure was to kill the app and open it again, and the only way to know that was the cure was
        // to have written the app.
        syncStateHandle = service.state(listener: SyncStateObserver { [weak self] state in
            Task { @MainActor [weak self] in
                await self?.syncStateChanged(to: state)
            }
        })

        // The one that matters: a loop started after `stop()` is the zombie.
        guard isStillWanted(started) else { return }
        isPaused = false
        await service.start()
    }

    /// The sync loop has stopped and nobody asked it to. Start it again.
    ///
    /// After a pause, because the ordinary cause is a network that has gone away, and a restart into
    /// the same absent network is an error that produces a restart that produces an error. This is
    /// not a backoff — a fixed wait is enough to turn a hot loop into a slow one, and the SDK does
    /// its own retrying underneath.
    private func syncStateChanged(to state: SyncServiceState) async {
        // The one place in the app that learns anything about the network at all, which is why the
        // screens read the fact from here rather than from a reachability monitor of their own. It is
        // also the *better* fact: `NWPathMonitor` reports on the interface, and an interface is up
        // behind a captive portal, on a VPN with no route, and in front of a homeserver that is
        // simply down. This reports on whether we are reaching the server, which is the thing the
        // user actually cares about.
        let wasOffline = isOffline
        isOffline = state == .offline

        // Everything the send queue could not get rid of while the network was gone. The SDK stops a
        // room's queue on failure and does not start it again by itself, so without this the messages
        // written offline sit there after the network is back, and the only cure is to press retry on
        // each one — which reads as an app that lost them.
        if state == .running {
            // Sooner than any backoff, so the backoff is let go of: the network is back, and the
            // next failure is a new story.
            sendQueueRestart?.cancel()
            sendQueueRestart = nil
            sendQueueRecovery.reset()
            await client.enableAllSendQueues(enable: true)
        }

        // And whoever else has to know. The room the reader is *in* stopped asking for history the
        // first time a page failed — it had to, or it would have asked once per frame of every scroll
        // — and nothing in that room can tell that the network is back. Only this can. See
        // `TimelineStore.connectivityChanged` and `UserSession`, which is what carries it there.
        if wasOffline != isOffline {
            await onConnectivityChange?(isOffline)
        }

        switch state {
        case .error, .terminated:
            break
        case .idle, .running, .offline:
            return
        }

        guard !hasStopped, !isPaused, !isRestartingSync else { return }

        isRestartingSync = true
        defer { isRestartingSync = false }

        Log.session.error("the sync loop stopped by itself; starting it again")

        try? await Task.sleep(for: Self.syncRestartDelay)

        // Everything may have changed while we waited: the user may have signed out, or put the app
        // in their pocket. Both of those took sync down on purpose, and neither wants it back.
        guard !hasStopped, !isPaused else { return }

        await syncService?.start()
    }

    private static let syncRestartDelay: Duration = .seconds(2)

    /// A room's send queue has stopped itself on a failure that may pass. Start it again — later.
    ///
    /// Not while offline: there the sync loop reports the network back and starts every queue at
    /// once (`syncStateChanged`), and a timer firing into no network would only stop them again and
    /// lengthen the next pause for nothing. And never two restarts waiting at once — the pause is the
    /// point, and a second failure arriving inside it is the same bad moment, not a new one.
    private func sendQueueStopped() {
        guard !hasStopped, !isOffline, sendQueueRestart == nil else { return }

        let pause = sendQueueRecovery.failed()
        Log.session.info("a send queue stopped itself; starting it again in \(pause, privacy: .public)")

        sendQueueRestart = Task { [weak self] in
            try? await Task.sleep(for: pause)
            guard let self, !Task.isCancelled else { return }
            self.sendQueueRestart = nil
            guard !self.hasStopped, !self.isOffline else { return }
            await self.client.enableAllSendQueues(enable: true)
        }
    }

    /// The app has gone into the user's pocket.
    ///
    /// Sync is stopped rather than left running, and the reason is not battery. A push arriving is
    /// precisely the moment iOS wakes the *notification extension*, which is a second process that
    /// opens the same SQLite store — so a backgrounded app holding a live sync loop is holding that
    /// store open exactly when something else needs it. Suspended by the system mid-write, it holds
    /// it open for as long as the system feels like.
    ///
    /// Not called on the Mac. A Mac app that is not in front is still an app the user expects to be
    /// receiving messages, and there is no extension racing it for the file.
    public func pause() async {
        guard !hasStopped, let syncService else { return }

        isPaused = true
        await syncService.stop()
    }

    /// And back out of it. `start()` on the service, not on this store: the listeners, the streams
    /// and the room handles were never taken down, only the loop that feeds them.
    public func resume() async {
        guard !hasStopped, isPaused, let syncService else { return }

        isPaused = false
        await syncService.start()
    }

    /// Shuts the list down, and means it.
    ///
    /// This used to cancel the rebuild timer, cancel the send-queue handle, and stop the sync
    /// service — and leave the **entries stream running**, because nobody had ever taken its
    /// `TaskHandle`. It also left `syncService` non-nil, so `start()` could never run again
    /// (`guard syncService == nil`); the store was permanently dead and looked perfectly alive.
    ///
    /// The live stream is the dangerous half. `UserSession.signOut()` calls this and then logs
    /// out — which **deletes the SQLite store off the disk**. A diff still in the Rust queue then
    /// arrives, `apply` takes it, `scheduleRebuild` starts a *new* task (the one cancelled here is
    /// long gone), and `rebuildSummaries` begins calling `roomInfo()` and `latestEvent()` on room
    /// handles whose database no longer exists.
    ///
    /// So the handle is cancelled, everything is released, and `hasStopped` catches whatever was
    /// already in the air: a cancelled handle stops *new* diffs, it cannot recall the one that has
    /// already crossed the FFI boundary and is waiting on a `Task { @MainActor }` hop.
    public func stop() async {
        hasStopped = true
        localNameObserver = nil

        // Anything already in flight belongs to the account we are leaving. Cancelling a task does
        // not reach one that is awaiting inside the SDK, and the one that matters here is the
        // rebuild — see `scheduleRebuild`, whose tail used to clear a registration it no longer
        // owned.
        generation += 1

        rebuildTask?.cancel()
        rebuildTask = nil

        entriesHandle?.cancel()
        entriesHandle = nil

        // The queue the diffs came down, and the task draining it. `hasStopped` above still stands
        // guard over anything already in flight — this only shuts the road.
        entriesContinuation?.finish()
        entriesContinuation = nil
        entriesTask?.cancel()
        entriesTask = nil

        sendQueueHandle?.cancel()
        sendQueueHandle = nil

        sendQueueErrorHandle?.cancel()
        sendQueueErrorHandle = nil
        sendQueueRestart?.cancel()
        sendQueueRestart = nil
        sendQueueRecovery.reset()

        typingHandles.values.forEach { $0.cancel() }
        typingHandles = [:]
        typingRoomIDs = []

        // Before the service is stopped, not after: stopping it is going to move it to a state the
        // observer is watching for, and an observer still listening at that moment would take a
        // deliberate shutdown for a failure and start the whole thing up again on the way out.
        syncStateHandle?.cancel()
        syncStateHandle = nil

        // Bounded, and for the same reason `logout` is: this is on the path out of the account,
        // and the way out of an account must not depend on the network being well. A sync service
        // that will not stop used to hold the whole sign-out, which held the whole app.
        if let syncService {
            _ = try? await withTimeout(Self.stopTimeout) {
                await syncService.stop()
            }
        }

        syncService = nil
        roomList = nil
        entriesResult = nil
        orderedRooms = []

        // The delegate is a retain cycle waiting to happen — the SDK holds it, it holds us — and
        // more to the point it is a callback into a store for an account that is being signed out
        // of. Cleared before the settings object goes with it.
        notificationSettings?.setDelegate(delegate: nil)
        notificationSettings = nil
        notificationWatcher = nil
        mutedRoomIDs = []

        // And the screen forgets the conversations. This store is only ever stopped on the way out
        // of an account, and a list of somebody's chats — their names, their faces, the last thing
        // each of them said — is not a thing to leave published on a signed-out app because the
        // view tree happened to come down first. `isLoadingInitialRooms` goes back up with it: the
        // next account starts by loading, not by showing an empty list it has not looked at yet.
        rooms = []
        isLoadingInitialRooms = true
        needsRebuild = false
    }

    // MARK: - Diff handling

    private func apply(diffs: [RoomListEntriesUpdate]) {
        // Already on its way when we shut down. Acting on it means touching room handles whose
        // store may have just been deleted from under them — see `stop()`.
        guard !hasStopped else { return }

        for diff in diffs {
            switch diff {
            case let .append(values):
                orderedRooms.append(contentsOf: values)
            case .clear:
                orderedRooms.removeAll()
            case let .pushFront(value):
                orderedRooms.insert(value, at: 0)
            case let .pushBack(value):
                orderedRooms.append(value)
            case .popFront:
                if !orderedRooms.isEmpty { orderedRooms.removeFirst() }
            case .popBack:
                if !orderedRooms.isEmpty { orderedRooms.removeLast() }
            // An index we do not have — the same fault, and the same refusal to paper over it, as
            // in `TimelineStore.apply`. Our copy of the list is no longer the list the SDK is
            // describing, and a clamped insert or a swallowed remove would leave it wrong forever
            // while looking perfectly healthy: one conversation quietly in the wrong place, which
            // reads as a list sorted by something you have misremembered rather than as a bug.
            case let .insert(index, value):
                let i = Int(index)
                guard i <= orderedRooms.count else {
                    return desynced("insert at \(i) of \(orderedRooms.count)")
                }
                orderedRooms.insert(value, at: i)
            case let .set(index, value):
                let i = Int(index)
                guard orderedRooms.indices.contains(i) else {
                    return desynced("set at \(i) of \(orderedRooms.count)")
                }
                orderedRooms[i] = value
            case let .remove(index):
                let i = Int(index)
                guard orderedRooms.indices.contains(i) else {
                    return desynced("remove at \(i) of \(orderedRooms.count)")
                }
                orderedRooms.remove(at: i)
            case let .truncate(length):
                let n = Int(length)
                guard n <= orderedRooms.count else {
                    return desynced("truncate to \(n) of \(orderedRooms.count)")
                }
                orderedRooms.removeSubrange(n...)

            case let .reset(values):
                orderedRooms = values
            }
        }

        scheduleRebuild()
    }

    /// The list is no longer the list the SDK is describing, so it is asked for again.
    ///
    /// Cheaper than the timeline's answer to the same problem, and only because this store has
    /// somewhere cheaper to go: setting the filter again makes the dynamic adapter re-emit its
    /// entries as a `reset`, which is the SDK's own account of the list — the thing we have lost.
    /// The sync service is not touched, no room handle is rebuilt, and the screen is not emptied:
    /// `reset` replaces `orderedRooms` wholesale and the summaries are rebuilt from it.
    ///
    /// An `assertionFailure` in debug for the same reason as the timeline's: there is no index the
    /// SDK is entitled to send us that we cannot hold, so if we cannot hold one, it is our bug.
    private func desynced(_ what: String) {
        guard !isResyncing, let entriesResult else { return }
        isResyncing = true

        Log.rooms.error("Room list out of step with the SDK: \(what, privacy: .public). Asking for it again.")
        assertionFailure("Room list desynchronised: \(what)")

        _ = entriesResult.controller().setFilter(kind: Self.filter)
        isResyncing = false
    }

    /// Coalesces a burst of diffs into one rebuild — without ever letting the burst prevent one.
    ///
    /// It used to be cancel-and-restart: every diff killed the rebuild in flight and started the
    /// 50 ms timer again. That coalesces beautifully when the diffs stop, and starves completely
    /// when they do not. `rebuildSummaries` is a sequential FFI round-trip *per room*, so on an
    /// account with a few hundred rooms it takes real time — and during initial sync the diffs and
    /// the send-queue updates keep coming for the whole of it. Each one cancelled the rebuild part
    /// way through, `rooms` was never assigned, `isLoadingInitialRooms` never went false, and the
    /// user sat looking at the empty-chats screen with every one of their conversations already in
    /// the store behind it.
    ///
    /// Trailing edge instead: one rebuild runs to completion, and anything that arrives while it
    /// is running raises a flag rather than a knife. When it finishes, it looks at the flag and
    /// goes round again. Bursts still collapse — a hundred diffs during one rebuild are one more
    /// rebuild, not a hundred — but a rebuild always *finishes*.
    private func scheduleRebuild() {
        needsRebuild = true
        guard rebuildTask == nil else { return }

        // Which run of the list this rebuild belongs to. `stop()` bumps it, and the tail below
        // checks it — because the tail used to clear `rebuildTask` unconditionally, and that is
        // one variable being cleared by somebody who no longer owns it.
        //
        // The way it goes wrong: `stop()` cancels the task and nils the field, but a task sitting
        // in `await rebuildSummaries()` is not stopped by either. `start()` runs again, a diff
        // arrives, a *new* rebuild is registered — and then the old one finally wakes up and sets
        // `rebuildTask = nil`, erasing the registration of a task that is still running. The next
        // diff sees nil, starts a third, and now two rebuilds are walking `orderedRooms` and
        // writing `rooms`, with the slower one winning: the chat list settles on the older answer.
        let generation = self.generation

        rebuildTask = Task { [weak self] in
            // Let the first burst settle before doing any of the async work.
            try? await Task.sleep(for: Self.debounce)

            while let self, self.needsRebuild, !Task.isCancelled, generation == self.generation {
                self.needsRebuild = false
                await self.rebuildSummaries()
            }

            guard let self, generation == self.generation else { return }
            self.rebuildTask = nil
        }
    }

    /// Which run of the list we are on. See `scheduleRebuild` and `stop()`.
    private var generation = 0

    /// How long a burst of diffs is allowed to settle before the summaries are rebuilt.
    ///
    /// Named because it is described by name in `CLAUDE.md` — "coalesces bursts of diffs with a
    /// 50 ms debounce" — and a number that the documentation refers to and the code spells out by
    /// hand is a number that drifts apart from its own description.
    private static let debounce = Duration.milliseconds(50)

    /// A diff arrived while a rebuild was already running, so another one is owed. See
    /// `scheduleRebuild`.
    private var needsRebuild = false

    /// The rooms this account has silenced by name, so the list can draw their badges grey.
    ///
    /// Held here rather than asked per row, because asking is a round trip: the badge is drawn for
    /// every conversation on the screen, and a rebuild already costs one `roomInfo()` and one
    /// `latestEvent()` each. This is two calls for the *whole list* — the rooms with a rule of
    /// their own, and then that rule — and there are only ever a handful of those.
    private var mutedRoomIDs: Set<String> = []

    /// Kept for the delegate below, which the SDK holds only weakly-by-convention: an object we
    /// dropped would stop being told, and the badges would then be correct until the first time
    /// somebody muted something.
    private var notificationSettings: NotificationSettings?
    private var notificationWatcher: NotificationSettingsWatcher?

    /// Reads the silenced rooms, and arranges to be told when they change.
    ///
    /// Failures are swallowed on purpose and the set is simply left as it was. Every one of these
    /// calls can fail — an account whose push rules have never been fetched, a server that is not
    /// answering — and none of those is a reason to stop drawing a chat list. The cost of being
    /// wrong is a badge in the wrong colour, which is the mildest thing on the screen; the cost of
    /// treating it as an error would be a list that does not appear.
    private func watchMuting() async {
        let settings = await client.getNotificationSettings()
        notificationSettings = settings

        let watcher = NotificationSettingsWatcher { [weak self] in
            Task { @MainActor [weak self] in
                await self?.reloadMuting()
                self?.scheduleRebuild()
            }
        }
        notificationWatcher = watcher
        settings.setDelegate(delegate: watcher)

        await reloadMuting()
    }

    /// The set itself. Two calls for the whole list — see `mutedRoomIDs`.
    private func reloadMuting() async {
        guard let settings = notificationSettings else { return }

        // `nil` rather than `true`: the argument asks whether the rule is *enabled*, which is not
        // the same question as what the rule says. A disabled mute is still a room with a rule of
        // its own, and asking the mode below is what actually settles it.
        let withRules = await settings.getRoomsWithUserDefinedRules(enabled: nil)

        var muted: Set<String> = []
        for roomID in withRules {
            guard let mode = try? await settings.getUserDefinedRoomNotificationMode(roomId: roomID),
                  mode == .mute else { continue }
            muted.insert(roomID)
        }

        mutedRoomIDs = muted
    }

    private func rebuildSummaries() async {
        let handles = orderedRooms

        var summaries: [RoomSummary] = []
        summaries.reserveCapacity(handles.count)

        for room in handles {
            guard !Task.isCancelled else { return }
            guard let info = try? await room.roomInfo() else { continue }

            var preview: String?
            var activity: Date?

            switch await room.latestEvent() {
            case let .remote(timestamp, _, _, _, content):
                preview = MessagePreview.text(for: content)
                activity = MessagePreview.date(from: timestamp)
            case let .local(timestamp, _, _, content, _):
                preview = MessagePreview.text(for: content)
                activity = MessagePreview.date(from: timestamp)
            default:
                break
            }

            guard let summary = RoomSummary(info: info,
                                            ownUserID: ownUserID,
                                            lastMessage: preview,
                                            lastActivity: activity,
                                            isMuted: mutedRoomIDs.contains(info.id)) else {
                continue
            }
            summaries.append(summary)
        }

        guard !Task.isCancelled else { return }
        watchTyping(in: handles)
        // One list in, two lists out: the archive is everything the user swept aside, the main list
        // is the rest. Both keep the same recency-and-pins order.
        let (active, archived) = Self.partitionArchived(summaries)
        rooms = Self.byRecency(active)
        archivedRooms = Self.byRecency(archived)
        isLoadingInitialRooms = false
    }

    /// Keeps one typing subscription per room in the list: new rooms are listened to, rooms that
    /// have left the list are let go of.
    private func watchTyping(in handles: [Room]) {
        var current: Set<String> = []
        let ownUserID = ownUserID

        for room in handles {
            let roomID = room.id()
            current.insert(roomID)
            guard typingHandles[roomID] == nil else { continue }

            typingHandles[roomID] = room.subscribeToTypingNotifications(listener: TypingListener { [weak self] userIDs in
                // The server echoes our own notice back with everybody else's; that one is not news.
                let others = userIDs.contains { $0 != ownUserID }
                Task { @MainActor [weak self] in
                    guard let self, !self.hasStopped else { return }
                    if others {
                        self.typingRoomIDs.insert(roomID)
                    } else {
                        self.typingRoomIDs.remove(roomID)
                    }
                }
            })
        }

        for (roomID, handle) in typingHandles where !current.contains(roomID) {
            handle.cancel()
            typingHandles[roomID] = nil
            typingRoomIDs.remove(roomID)
        }
    }

    /// Splits the summaries into the ones the main list shows and the ones the archive holds. Pulled
    /// out and `static` so the split is testable without a homeserver behind it — it is the whole of
    /// what tells the archive apart from the list.
    static func partitionArchived(_ summaries: [RoomSummary]) -> (active: [RoomSummary], archived: [RoomSummary]) {
        var active: [RoomSummary] = []
        var archived: [RoomSummary] = []
        for summary in summaries {
            if summary.isArchived {
                archived.append(summary)
            } else {
                active.append(summary)
            }
        }
        return (active, archived)
    }

    // MARK: - Invitations

    /// Accepts an invitation. The room becomes an ordinary room.
    ///
    /// The list is not touched here. Joining changes the room's membership on the server, the
    /// server tells the sync loop, the sync loop emits a diff, and the row redraws itself as a
    /// chat — which is the same road every other change to a room takes, and the only one that
    /// cannot disagree with what is actually true.
    public func accept(roomID: String) async {
        do {
            _ = try await client.joinRoomById(roomId: roomID)
        } catch {
            Log.rooms.error("the invitation would not be accepted: \(Log.describe(error), privacy: .public)")
            failure = .acceptInvite
        }
    }

    /// Declines an invitation.
    ///
    /// Which is `leave()`, and that is not a workaround: Matrix has no "reject" — the SDK's own
    /// documentation on `Room.leave` says "only invited and joined rooms can be left", and leaving
    /// a room you were invited to *is* the decline. The room then fails the `.nonLeft` filter and
    /// drops out of the list on its own.
    public func decline(roomID: String) async {
        guard let room = room(withID: roomID) else {
            failure = .declineInvite
            return
        }

        do {
            try await room.leave()
        } catch {
            Log.rooms.error("the invitation would not be declined: \(Log.describe(error), privacy: .public)")
            failure = .declineInvite
        }
    }

    // MARK: - Organising the list

    /// Pins a room to the top, or unpins it. This is the Matrix `m.favourite` tag, so the pin syncs
    /// across the user's devices rather than living on this one.
    ///
    /// The list is not touched here, for the same reason `accept` does not touch it: the tag change
    /// reaches the server, the server tells the sync loop, a diff comes back, and the row re-sorts
    /// itself through `byRecency`. `tagOrder` is left to the SDK — explicit hand-ordering of pins is
    /// layered on top by whoever drags one.
    public func setPinned(roomID: String, _ pinned: Bool) async {
        await act(roomID, .pin) { try await $0.setIsFavourite(isFavourite: pinned, tagOrder: nil) }
    }

    /// Archives a room, or lifts it back out. This is the Matrix `m.lowpriority` tag — the nearest
    /// thing the protocol has to an archive. The room's history is untouched; it is filtered out of
    /// the main list (see `Self.filter`) and shown on the archive screen instead.
    public func setArchived(roomID: String, _ archived: Bool) async {
        await act(roomID, .archive) { try await $0.setIsLowPriority(isLowPriority: archived, tagOrder: nil) }
    }

    /// Marks a room read — clears its unread count and drops any hand-set unread flag.
    ///
    /// Both halves by hand, and the second is not belt and braces. `markAsRead` sends the receipt
    /// and the SDK's own documentation is explicit that it *"does NOT unset the unread flag; it's
    /// the caller's responsibility"* — so the sentence above used to be a description of what this
    /// was meant to do rather than of what it did: mark unread, mark read, and the badge stayed.
    public func markRead(roomID: String) async {
        await act(roomID, .read) {
            try await $0.markAsRead(receiptType: .read)
            try await $0.setUnreadFlag(newValue: false)
        }
    }

    /// Flags a read room unread by hand. Distinct from having unread messages: the badge comes back
    /// even though there is nothing new to read, because the user asked to be reminded.
    public func markUnread(roomID: String) async {
        await act(roomID, .read) { try await $0.setUnreadFlag(newValue: true) }
    }

    /// Leaves a room. This is the same call `decline` makes, but named for what a joined room's
    /// swipe means — "delete this chat" — rather than for an invitation. Matrix has no delete; you
    /// leave, the room fails the `.nonLeft` filter, and the row drops out on its own.
    public func leave(roomID: String) async {
        await act(roomID, .leave) { try await $0.leave() }
    }

    /// Reports a whole room to its moderators / the homeserver. Content-level reports (one message)
    /// go through the timeline; this is the room itself.
    public func reportRoom(roomID: String, reason: String) async {
        await act(roomID, .report) { try await $0.reportRoom(reason: reason) }
    }

    /// The shape every room-list action shares: resolve the handle, run the SDK call, and on failure
    /// log without leaking content and surface a sentence the user can act on. Kept in one place so
    /// a new action is one line, not a repeated do/catch that quietly drifts.
    private func act(_ roomID: String,
                     _ failureKind: RoomActionFailure,
                     _ body: (Room) async throws -> Void) async {
        guard let room = room(withID: roomID) else {
            failure = failureKind
            return
        }
        do {
            try await body(room)
        } catch {
            Log.rooms.error("room action \(failureKind.rawValue, privacy: .public) failed: \(Log.describe(error), privacy: .public)")
            failure = failureKind
        }
    }

    /// Newest conversation first — sorted here rather than taken from the SDK's order.
    ///
    /// The two nearly always agree, and where they part company the SDK is answering a
    /// different question. Its list is ordered by what the *server* knows, and a message
    /// still sitting in the send queue is by definition something the server knows nothing
    /// about. So a message that failed to send moved its room's preview and its timestamp —
    /// both read from `latestEvent()`, which does count local echoes — while leaving the row
    /// itself wherever it was. Throwing that message away moved them back, and again left the
    /// row where it was. The order and the timestamps beside it were describing two different
    /// lists, and the user was reading both at once.
    ///
    /// Sorting on `lastActivity` makes the position and the time on the row the same fact.
    /// Ties keep the SDK's order, so a burst of rooms that share a timestamp does not
    /// reshuffle itself on every rebuild; a room with nothing in it at all has no recency to
    /// claim and sinks to the bottom.
    static func byRecency(_ summaries: [RoomSummary]) -> [RoomSummary] {
        summaries.enumerated()
            .sorted { left, right in
                // Invitations first, and this is not a decoration. An invited room has no messages
                // in it, so it has no `lastActivity` — which means the recency sort below would
                // sink every invitation to the *bottom* of the list, underneath every conversation
                // the user has ever had. The one row that is asking them a question would be the
                // last one they ever saw.
                if left.element.isInvitation != right.element.isInvitation {
                    return left.element.isInvitation
                }

                // Pinned rooms sit above the rest — beneath invitations, which are still the one
                // thing asking for an answer. This is the `m.favourite` tag, so the pin travels
                // with the account, not the device. Within the pinned group the ordinary recency
                // rule below still decides; explicit hand-reordering (the favourite tag's order)
                // is layered on top where the user drags a pin, not here.
                if left.element.isPinned != right.element.isPinned {
                    return left.element.isPinned
                }

                return switch (left.element.lastActivity, right.element.lastActivity) {
                case let (leftActivity?, rightActivity?) where leftActivity != rightActivity:
                    leftActivity > rightActivity
                case (nil, .some): false
                case (.some, nil): true
                default: left.offset < right.offset
                }
            }
            .map(\.element)
    }

    /// Fetches the live handle for a room, which the timeline needs.
    func room(withID id: String) -> Room? {
        orderedRooms.first { $0.id() == id }
    }
}

/// The account's notification rules moved. Which rule is not said, and does not need to be: the
/// list answers by reading the silenced rooms again, which is the fetch it would have had to make
/// to act on anything more specific.
private final class NotificationSettingsWatcher: NotificationSettingsDelegate {
    private let onChange: @Sendable () -> Void

    init(onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
    }

    func settingsDidChange() {
        onChange()
    }
}

/// Says only that some room's send queue stopped itself. Which room and why are dropped: the
/// answer is the same call for every room, and the error is the SDK's to report on the message.
private final class SendQueueErrorListener: SendQueueRoomErrorListener {
    private let onError: @Sendable () -> Void

    init(onError: @escaping @Sendable () -> Void) {
        self.onError = onError
    }

    func onError(roomId: String, error: ClientError) {
        onError()
    }
}

/// Bridges the SDK's callback protocol into a Swift closure.
private final class EntriesListener: RoomListEntriesListener {
    private let onDiff: @Sendable ([RoomListEntriesUpdate]) -> Void

    init(onDiff: @escaping @Sendable ([RoomListEntriesUpdate]) -> Void) {
        self.onDiff = onDiff
    }

    func onUpdate(roomEntriesUpdate: [RoomListEntriesUpdate]) {
        onDiff(roomEntriesUpdate)
    }
}

/// Says only that the send queue moved, not how.
///
/// The update itself is dropped on purpose. Every one of them — enqueued, sent, failed,
/// cancelled — means the same thing here: some room's newest message is not what we last
/// thought it was. `rebuildSummaries` then asks the rooms themselves, which is the answer
/// we would have had to go and fetch anyway. Nothing about the message travels across this
/// hop, which also means nothing non-`Sendable` does.
/// The sync loop reporting on itself. `SyncServiceState` is a plain enum and already `Sendable`, so
/// it crosses to the main actor as it is — no `UnsafeTransfer` needed, unlike the diffs.
private final class SyncStateObserver: SyncServiceStateObserver {
    private let onState: @Sendable (SyncServiceState) -> Void

    init(onState: @escaping @Sendable (SyncServiceState) -> Void) {
        self.onState = onState
    }

    func onUpdate(state: SyncServiceState) {
        onState(state)
    }
}

private final class SendQueueListener: SendQueueRoomUpdateListener {
    private let onUpdate: @Sendable () -> Void

    init(onUpdate: @escaping @Sendable () -> Void) {
        self.onUpdate = onUpdate
    }

    func onUpdate(roomId: String, update: RoomSendQueueUpdate) {
        onUpdate()
    }
}
