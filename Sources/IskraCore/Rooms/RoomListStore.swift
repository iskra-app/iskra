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

        await service.start()
    }

    public func stop() async {
        rebuildTask?.cancel()
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
        rooms = summaries
        isLoadingInitialRooms = false
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
