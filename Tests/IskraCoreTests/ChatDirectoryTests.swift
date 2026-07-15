import Foundation
import Testing
@testable import IskraCore

/// The shared slots App Intents and the app pass through. The intents run in their own process, so
/// the round-trips have to be exact — and the reads that clear (a pending open, the outbox) have to
/// clear, or an intent's request would be acted on again on every foreground.
@Suite("ChatDirectory")
struct ChatDirectoryTests {
    /// A throwaway defaults, so the tests do not touch the real App Group. A fixed suite name is
    /// cleared at the start of each test.
    private func freshDefaults() -> UserDefaults {
        let suite = "iskra.tests.chatDirectory"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test("the directory round-trips")
    func directoryRoundTrips() {
        let defaults = freshDefaults()
        let entries = [ChatDirectoryEntry(id: "!a", name: "Кухня"),
                       ChatDirectoryEntry(id: "!b", name: "Работа")]
        ChatDirectory.writeDirectory(entries, to: defaults)
        #expect(ChatDirectory.directory(from: defaults) == entries)
    }

    @Test("an empty directory reads as empty, not nil")
    func emptyDirectory() {
        #expect(ChatDirectory.directory(from: freshDefaults()).isEmpty)
    }

    @Test("a pending open is read once, then gone")
    func pendingOpenIsOneShot() {
        let defaults = freshDefaults()
        ChatDirectory.requestOpen(roomID: "!room", in: defaults)
        #expect(ChatDirectory.takePendingOpen(from: defaults) == "!room")
        #expect(ChatDirectory.takePendingOpen(from: defaults) == nil)
    }

    @Test("the outbox accumulates and then drains empty")
    func outboxDrains() {
        let defaults = freshDefaults()
        ChatDirectory.enqueue(.init(roomID: "!a", text: "one"), in: defaults)
        ChatDirectory.enqueue(.init(roomID: "!b", text: "two"), in: defaults)

        let drained = ChatDirectory.drainOutbox(from: defaults)
        #expect(drained.map(\.text) == ["one", "two"])
        #expect(drained.map(\.roomID) == ["!a", "!b"])
        // Drained means gone — the app must not send them twice.
        #expect(ChatDirectory.drainOutbox(from: defaults).isEmpty)
    }
}
