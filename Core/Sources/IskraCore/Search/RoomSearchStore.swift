import Foundation
import Observation
import MatrixRustSDK

/// Searching inside one conversation, as opposed to `SearchStore`, which searches them all.
///
/// It runs against the same local encrypted index and never touches the homeserver. The SDK no
/// longer searches one room on its own (26.08 dropped `Room.searchMessages`), so this is the global
/// search with this room's hits kept — `MessageSearch` turns pages until there are enough. The results are the same `SearchHit` the room list already
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
    /// Who runs the search — `nil` for a timeline made without a session (tests), which finds nothing.
    private let client: Client?
    private let roomID: String
    private let ownUserID: String
    private var searchTask: Task<Void, Never>?

    init(room: Room, client: Client?) {
        self.room = room
        self.client = client
        self.roomID = room.id()
        self.ownUserID = room.ownUserId()
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

        do {
            guard let client else {
                hits = []
                foundNothing = true
                return
            }
            let results = try await MessageSearch.results(client, query: query, limit: 50, roomID: roomID)
            guard !Task.isCancelled else { return }
            let counterpartID = LocalNames.name(for: roomID) == nil
                ? nil : await SearchStore.counterpart(in: room, ownUserID: ownUserID)
            guard !Task.isCancelled else { return }
            hits = results.compactMap { Self.hit(from: $0.result, roomID: roomID, counterpartID: counterpartID) }
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
    static func hit(from result: MessageSearchResult, roomID: String, counterpartID: String?) -> SearchHit? {
        guard let excerpt = SearchStore.excerpt(for: result.content) else { return nil }

        var displayName: String?
        if case let .ready(name, _, _, _, _) = result.senderProfile { displayName = name }

        return SearchHit(id: result.eventId,
                         roomID: roomID,
                         senderName: SearchStore.senderName(result.sender, displayName: displayName,
                                                            counterpartID: counterpartID,
                                                            localName: LocalNames.name(for: roomID)),
                         excerpt: excerpt,
                         timestamp: MessagePreview.date(from: result.timestamp))
    }
}
