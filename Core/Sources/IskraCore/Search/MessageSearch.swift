import Foundation
import MatrixRustSDK

/// One query against the SDK's local search index, for `SearchStore` and `RoomSearchStore` both.
///
/// Since 26.08 the SDK offers a single `SearchService` across every room — a page is a hundred
/// matches from all of them — and the room-scoped `Room.searchMessages` is gone from the FFI. So a
/// conversation searches with the same service and keeps its own matches, turning pages until it
/// has enough or the index runs out. The global search takes the first page as it is.
enum MessageSearch {
    /// How many pages (a hundred matches across all rooms each) to turn for the sake of one room.
    static let maxPages = 10

    /// Up to `limit` matches for `query`, in the index's order; with `roomID`, only that room's.
    static func results(_ client: Client, query: String, limit: Int,
                        roomID: String? = nil) async throws -> [(roomID: String, result: MessageSearchResult)] {
        let service = client.searchService()
        // The first page is loaded inside `setQuery`.
        try await service.setQuery(query: query)
        var pages = 1
        var found = await snapshot(service, roomID: roomID)
        while roomID != nil, found.count < limit, !ended(service), pages < maxPages, !Task.isCancelled {
            try await service.paginate()
            pages += 1
            found = await snapshot(service, roomID: roomID)
        }
        return Array(found.prefix(limit))
    }

    private static func ended(_ service: SearchService) -> Bool {
        if case let .idle(endReached) = service.paginationState() { return endReached }
        return false
    }

    /// What has been found so far. Subscribing hands the current list over as one `reset` before it
    /// returns — that is what we keep — and the subscription is dropped at once: anything later
    /// arrives only with the next page, which we ask for ourselves.
    private static func snapshot(_ service: SearchService,
                                 roomID: String?) async -> [(roomID: String, result: MessageSearchResult)] {
        let collector = Collector()
        let handle = await service.subscribeToResults(listener: collector)
        handle.cancel()
        return collector.values.compactMap { value in
            guard case let .message(id, result) = value, roomID == nil || id == roomID else { return nil }
            return (id, result)
        }
    }

    private final class Collector: SearchServiceResultsListener, @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [SearchServiceResult] = []

        var values: [SearchServiceResult] { lock.withLock { stored } }

        func onUpdate(updates: [SearchServiceResultsUpdate]) {
            for case let .reset(values) in updates {
                lock.withLock { stored = values }
            }
        }
    }
}
