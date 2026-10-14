import Foundation
import Observation
import MatrixRustSDK

/// Searching inside one conversation, as opposed to `SearchStore`, which searches them all.
///
/// It runs against the same local encrypted index and never touches the homeserver — but through
/// the room-scoped `Room.searchMessages`, which returns only this room's hits, rather than the
/// global one filtered down afterwards. The results are the same `SearchHit` the room list already
/// knows how to open, so a hit here jumps to the message the same way a hit from the global search
/// does.
///
/// One store per open room, made with the room's handle, like `TimelineStore`.
@MainActor
@Observable
public final class RoomSearchStore: Identifiable {
    public private(set) var hits: [SearchHit] = []
    public private(set) var isSearching = false
    /// True when a finished search found nothing, so the UI can say so rather than sit blank.
    public private(set) var foundNothing = false

    private let room: Room
    private let roomID: String
    private var searchTask: Task<Void, Never>?

    init(room: Room) {
        self.room = room
        self.roomID = room.id()
    }

    /// Searches as the user types, cancelling whatever was in flight. Same shape and same 200 ms
    /// settle as the global search — see `SearchStore.search`, whose reasoning about the spinner and
    /// the cancelled-task race applies here word for word.
    public func search(_ query: String) {
        searchTask?.cancel()

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            hits = []
            foundNothing = false
            isSearching = false
            return
        }

        isSearching = true
        foundNothing = false

        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, let self else { return }
            await run(query: trimmed)
        }
    }

    /// Clears the field without running anything — for closing the search.
    public func clear() {
        searchTask?.cancel()
        hits = []
        foundNothing = false
        isSearching = false
    }

    private func run(query: String) async {
        defer {
            if !Task.isCancelled { isSearching = false }
        }

        let iterator = room.searchMessages(query: query, numResultsPerBatch: 50)

        do {
            guard let results = try await iterator.nextEvents() else {
                guard !Task.isCancelled else { return }
                hits = []
                foundNothing = true
                return
            }

            guard !Task.isCancelled else { return }
            hits = results.compactMap { Self.hit(from: $0, roomID: roomID) }
            foundNothing = hits.isEmpty
        } catch {
            guard !Task.isCancelled else { return }
            hits = []
            foundNothing = true
        }
    }

    /// One room-scoped result into a `SearchHit`. A deleted message is dropped by
    /// `SearchStore.excerpt` — the words the query matched may still be in the index even though the
    /// message is gone, and a redaction must not come back as a result. See that method's note.
    static func hit(from result: RoomSearchResult, roomID: String) -> SearchHit? {
        guard let excerpt = SearchStore.excerpt(for: result.content) else { return nil }

        var senderName = result.sender
        if case let .ready(displayName, _, _) = result.senderProfile, let displayName {
            senderName = displayName
        }

        return SearchHit(id: result.eventId,
                         roomID: roomID,
                         senderName: senderName,
                         excerpt: excerpt,
                         timestamp: MessagePreview.date(from: result.timestamp))
    }
}
