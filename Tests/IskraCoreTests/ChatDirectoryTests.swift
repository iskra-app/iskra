import Foundation
import Testing
@testable import IskraCore

/// The shared slots App Intents and the app pass through. The intents run in their own process, so
/// the round-trips have to be exact — and the reads that clear (a pending open, the outbox) have to
/// clear, or an intent's request would be acted on again on every foreground.
@Suite("ChatDirectory")
struct ChatDirectoryTests {
    /// A throwaway defaults, so the tests do not touch the real App Group. The suite name is unique
    /// per test — these run in parallel, and a shared suite would let one test's write race another's
    /// read (which it did, once).
    private func freshDefaults(_ name: String) -> UserDefaults {
        let suite = "iskra.tests.chatDirectory.\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test("the directory round-trips")
    func directoryRoundTrips() {
        let defaults = freshDefaults("roundTrip")
        let entries = [ChatDirectoryEntry(id: "!a", name: "Кухня"),
                       ChatDirectoryEntry(id: "!b", name: "Работа")]
        ChatDirectory.writeDirectory(entries, to: defaults)
        #expect(ChatDirectory.directory(from: defaults) == entries)
    }

    @Test("an empty directory reads as empty, not nil")
    func emptyDirectory() {
        #expect(ChatDirectory.directory(from: freshDefaults("empty")).isEmpty)
    }

    @Test("a pending open is read once, then gone")
    func pendingOpenIsOneShot() {
        let defaults = freshDefaults("pendingOpen")
        ChatDirectory.requestOpen(roomID: "!room", in: defaults)
        #expect(ChatDirectory.takePendingOpen(from: defaults) == "!room")
        #expect(ChatDirectory.takePendingOpen(from: defaults) == nil)
    }

    @Test("the outbox accumulates and then drains empty")
    func outboxDrains() {
        let defaults = freshDefaults("outbox")
        ChatDirectory.enqueue(.init(roomID: "!a", text: "one"), in: defaults)
        ChatDirectory.enqueue(.init(roomID: "!b", text: "two"), in: defaults)

        let drained = ChatDirectory.drainOutbox(from: defaults)
        #expect(drained.map(\.text) == ["one", "two"])
        #expect(drained.map(\.roomID) == ["!a", "!b"])
        // Drained means gone — the app must not send them twice.
        #expect(ChatDirectory.drainOutbox(from: defaults).isEmpty)
    }

    /// What the Share extension adds: files alongside the words, which have to come out the other
    /// side exactly as they went in.
    @Test("shared files ride in the outbox with the words")
    func attachmentsRoundTrip() {
        let defaults = freshDefaults("attachments")
        let photo = ChatDirectory.OutboxAttachment(kind: .image, filename: "A/IMG_0001.HEIC")
        let file = ChatDirectory.OutboxAttachment(kind: .file, filename: "B/отчёт.pdf")
        ChatDirectory.enqueue(.init(roomID: "!a", text: "смотри", attachments: [photo, file]), in: defaults)

        let drained = ChatDirectory.drainOutbox(from: defaults)
        #expect(drained.first?.attachments == [photo, file])
        #expect(drained.first?.text == "смотри")
    }

    /// An outbox written by a build from before attachments existed — a Shortcut queued the message,
    /// then the app was updated before it came up. It has no `attachments` key at all, and must
    /// still send rather than be thrown away as unreadable.
    @Test("an outbox from before attachments still drains")
    func oldOutboxStillDecodes() throws {
        let defaults = freshDefaults("oldOutbox")
        let old = #"[{"roomID":"!a","text":"привет"}]"#.data(using: .utf8)!
        defaults.set(old, forKey: "appIntents.outbox")

        let drained = ChatDirectory.drainOutbox(from: defaults)
        #expect(drained.map(\.text) == ["привет"])
        #expect(drained.first?.attachments == [])
    }
}
