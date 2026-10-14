import Foundation
import Observation
import MatrixRustSDK

public struct SearchHit: Sendable, Identifiable, Equatable {
    public let id: String
    public let roomID: String
    public let senderName: String
    public let excerpt: String
    public let timestamp: Date
}

/// Searching the user's messages.
///
/// This runs entirely on the device, against the SDK's local search index — the one
/// we encrypt with a Keychain-held key in `AuthenticationService`. The query is
/// never sent to the homeserver, which matters: in an end-to-end encrypted room the
/// server could not search for us anyway, and asking it to would tell it what the
/// user is looking for.
@MainActor
@Observable
public final class SearchStore {
    public private(set) var hits: [SearchHit] = []
    public private(set) var isSearching = false
    /// True when a finished search found nothing, so the UI can say so rather than
    /// showing a blank screen.
    public private(set) var foundNothing = false

    private let client: Client
    private let ownUserID: String?
    private var searchTask: Task<Void, Never>?

    init(client: Client) {
        self.client = client
        self.ownUserID = try? client.userId()
    }

    /// Searches as the user types, cancelling whatever was in flight.
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
            // Wait for the typing to pause before hitting the index.
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, let self else { return }

            await run(query: trimmed)
        }
    }

    private func run(query: String) async {
        // Only the search that is still the current one may put the spinner out.
        //
        // This used to be a bare `defer { isSearching = false }`, which fires on *every* way out
        // — including the three `guard !Task.isCancelled` returns below. So a fast typist got
        // this: "hel" starts searching, "hell" cancels it and starts its own, and then the
        // cancelled one unwinds and turns off the spinner belonging to the search that is still
        // running. The screen says "nothing found" about a query it has not finished asking.
        defer {
            if !Task.isCancelled {
                isSearching = false
            }
        }

        do {
            let iterator = try await client.searchMessages(query: query,
                                                           filter: .rooms,
                                                           numResultsPerBatch: 50)
            guard let results = try await iterator.nextEvents() else {
                guard !Task.isCancelled else { return }
                hits = []
                foundNothing = true
                return
            }

            guard !Task.isCancelled else { return }

            hits = results.compactMap { hit(from: $0) }
            foundNothing = hits.isEmpty
        } catch {
            guard !Task.isCancelled else { return }
            hits = []
            foundNothing = true
        }
    }

    private func hit(from result: GlobalSearchResult) -> SearchHit? {
        let event = result.result
        guard let excerpt = Self.excerpt(for: event.content) else { return nil }

        var displayName: String?
        if case let .ready(name, _, _) = event.senderProfile { displayName = name }

        return SearchHit(id: event.eventId,
                         roomID: result.roomId,
                         senderName: Self.senderName(event.sender, displayName: displayName,
                                                     roomID: result.roomId, ownUserID: ownUserID),
                         excerpt: excerpt,
                         timestamp: MessagePreview.date(from: event.timestamp))
    }

    /// Who a result is from, as the rest of the app calls them.
    ///
    /// In a personal chat the user has given a name to, the other person goes by that name in a
    /// result too — the list, the header and the conversation already call them *Мама*, and a
    /// search that answered with `anna_1987` read as a message from a stranger. A nickname is only
    /// ever set on a personal chat (see `LocalNames`), so in a room that has one, anybody who is not
    /// us is the person it names.
    nonisolated static func senderName(_ senderID: String, displayName: String?,
                                       roomID: String, ownUserID: String?) -> String {
        if senderID != ownUserID, let local = LocalNames.name(for: roomID) { return local }
        return displayName ?? senderID
    }

    /// The words for one search result — or nil for an event that must not be a result at all.
    ///
    /// A deleted message may not come back from a search, and this is the only thing standing
    /// between it and the screen.
    ///
    /// The index holds the words; it is keyed by event ID and stores nothing else about the
    /// event. So a hit arrives as an event ID, and the SDK then loads the event *as it is now*
    /// — which, for a message that has since been deleted, is a redacted one. The words the
    /// query matched are the words the message used to say, and they are still in the index:
    /// the SDK drops an event from it when it sees the redaction, but only if it still holds
    /// the original event in its event cache, which it does not for old history and does not
    /// at all after `StorageStore.clearCache()`. There is no FFI to remove a document by hand.
    ///
    /// Handed that redacted event, `MessagePreview` would do exactly its job and return
    /// "Сообщение удалено" — and the deleted message would appear as a search result, matched
    /// by what it said, under its sender's name and the time it was sent. Being unable to
    /// *print* the words is not the same as not leaking them. So the rule here is narrower
    /// than a preview's: a hit must be a message that still exists, and everything else — a
    /// redaction above all — is not a hit and never reaches `hits`.
    nonisolated static func excerpt(for content: TimelineItemContent) -> String? {
        guard case let .msgLike(msgLike) = content,
              case let .message(message) = msgLike.kind else { return nil }

        return MessagePreview.text(for: message.msgType)
    }
}
