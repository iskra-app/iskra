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
    /// What the UI renders. Ordered by recency, as the server sorts it.
    public private(set) var rooms: [RoomSummary] = []

    /// True until the first batch of rooms arrives, so the UI can say something
    /// friendlier than showing an empty list.
    public private(set) var isLoadingInitialRooms = true

    private let client: Client
    private var syncService: SyncService?
    private var roomList: RoomList?
    private var entriesResult: RoomListEntriesWithDynamicAdaptersResult?

    /// Keeps the previews honest about messages that have not left yet — see `start()`.
    private var sendQueueHandle: TaskHandle?

    /// The room handles, in the order the SDK says they should appear.
    private var orderedRooms: [Room] = []

    /// Coalesces bursts of diffs into one summary rebuild. During initial sync the
    /// SDK can emit many updates in quick succession and rebuilding on each one
    /// would mean a stampede of `roomInfo()` calls.
    private var rebuildTask: Task<Void, Never>?

    public init(client: Client) {
        self.client = client
    }

    /// Starts syncing and streaming room updates. Safe to call once.
    public func start() async throws {
        guard syncService == nil else { return }

        let service = try await client.syncService().finish()
        syncService = service

        let list = try await service.roomListService().allRooms()
        roomList = list

        let listener = EntriesListener { [weak self] diffs in
            let transfer = UnsafeTransfer(value: diffs)
            Task { @MainActor [weak self] in
                self?.apply(diffs: transfer.value)
            }
        }

        let result = try await list.entriesWithDynamicAdapters(pageSize: 100, listener: listener)
        entriesResult = result
        _ = result.controller().setFilter(kind: .all(filters: []))

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
        sendQueueHandle = try await client.subscribeToSendQueueUpdates(listener: sendQueueListener)

        await service.start()
    }

    public func stop() async {
        rebuildTask?.cancel()
        sendQueueHandle?.cancel()
        sendQueueHandle = nil
        await syncService?.stop()
    }

    // MARK: - Diff handling

    private func apply(diffs: [RoomListEntriesUpdate]) {
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
            case let .insert(index, value):
                let i = min(Int(index), orderedRooms.count)
                orderedRooms.insert(value, at: i)
            case let .set(index, value):
                let i = Int(index)
                if orderedRooms.indices.contains(i) { orderedRooms[i] = value }
            case let .remove(index):
                let i = Int(index)
                if orderedRooms.indices.contains(i) { orderedRooms.remove(at: i) }
            case let .truncate(length):
                let n = Int(length)
                if n < orderedRooms.count { orderedRooms.removeSubrange(n...) }
            case let .reset(values):
                orderedRooms = values
            }
        }

        scheduleRebuild()
    }

    private func scheduleRebuild() {
        rebuildTask?.cancel()
        rebuildTask = Task { [weak self] in
            // Let a burst of diffs settle before doing the async work.
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled else { return }
            await self?.rebuildSummaries()
        }
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

            summaries.append(RoomSummary(info: info, lastMessage: preview, lastActivity: activity))
        }

        guard !Task.isCancelled else { return }
        rooms = Self.byRecency(summaries)
        isLoadingInitialRooms = false
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
    private static func byRecency(_ summaries: [RoomSummary]) -> [RoomSummary] {
        summaries.enumerated()
            .sorted { left, right in
                switch (left.element.lastActivity, right.element.lastActivity) {
                case let (l?, r?) where l != r: l > r
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
private final class SendQueueListener: SendQueueRoomUpdateListener {
    private let onUpdate: @Sendable () -> Void

    init(onUpdate: @escaping @Sendable () -> Void) {
        self.onUpdate = onUpdate
    }

    func onUpdate(roomId: String, update: RoomSendQueueUpdate) {
        onUpdate()
    }
}
