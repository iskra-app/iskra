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
    private var searchTask: Task<Void, Never>?

    init(client: Client) {
        self.client = client
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
        guard let excerpt = MessagePreview.text(for: event.content) else { return nil }

        var senderName = event.sender
        if case let .ready(displayName, _, _) = event.senderProfile, let displayName {
            senderName = displayName
        }

        return SearchHit(id: event.eventId,
                         roomID: result.roomId,
                         senderName: senderName,
                         excerpt: excerpt,
                         timestamp: MessagePreview.date(from: event.timestamp))
    }
}
