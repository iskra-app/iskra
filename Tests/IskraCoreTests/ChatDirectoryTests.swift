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
    private func freshDefaults(_ name: String) throws -> UserDefaults {
        let suite = "iskra.tests.chatDirectory.\(name)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test("the directory round-trips")
    func directoryRoundTrips() throws {
        let defaults = try freshDefaults("roundTrip")
        let entries = [ChatDirectoryEntry(id: "!a", name: "Кухня"),
                       ChatDirectoryEntry(id: "!b", name: "Работа")]
        ChatDirectory.writeDirectory(entries, to: defaults)
        #expect(ChatDirectory.directory(from: defaults) == entries)
    }

    @Test("an empty directory reads as empty, not nil")
    func emptyDirectory() throws {
        #expect(try ChatDirectory.directory(from: freshDefaults("empty")).isEmpty)
    }

    @Test("a pending open is read once, then gone")
    func pendingOpenIsOneShot() throws {
        let defaults = try freshDefaults("pendingOpen")
        ChatDirectory.requestOpen(roomID: "!room", in: defaults)
        #expect(ChatDirectory.takePendingOpen(from: defaults) == "!room")
        #expect(ChatDirectory.takePendingOpen(from: defaults) == nil)
    }

    @Test("the outbox accumulates and then drains empty")
    func outboxDrains() throws {
        let defaults = try freshDefaults("outbox")
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
    func attachmentsRoundTrip() throws {
        let defaults = try freshDefaults("attachments")
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
        let defaults = try freshDefaults("oldOutbox")
        let old = Data(#"[{"roomID":"!a","text":"привет"}]"#.utf8)
        defaults.set(old, forKey: "appIntents.outbox")

        let drained = ChatDirectory.drainOutbox(from: defaults)
        #expect(drained.map(\.text) == ["привет"])
        #expect(drained.first?.attachments == [])
    }

    // MARK: - More than one account

    @Test("each account replaces only its own chats")
    func accountsKeepTheirOwnChats() throws {
        let defaults = try freshDefaults("accounts")
        ChatDirectory.writeDirectory([ChatDirectoryEntry(id: "!a", name: "Кухня", accountID: "one")],
                                     account: "one", to: defaults)
        ChatDirectory.writeDirectory([ChatDirectoryEntry(id: "!a", name: "Кухня", accountID: "two")],
                                     account: "two", to: defaults)
        ChatDirectory.writeDirectory([ChatDirectoryEntry(id: "!b", name: "Работа", accountID: "one")],
                                     account: "one", to: defaults)

        let all = ChatDirectory.directory(from: defaults)
        #expect(all.filter { $0.accountID == "one" }.map(\.id) == ["!b"])
        #expect(all.filter { $0.accountID == "two" }.map(\.id) == ["!a"])
    }

    @Test("a signed-out account leaves the list and the outbox")
    func forgettingAnAccount() throws {
        let defaults = try freshDefaults("forget-account")
        ChatDirectory.writeDirectory([ChatDirectoryEntry(id: "!a", name: "Кухня", accountID: "one")],
                                     account: "one", to: defaults)
        ChatDirectory.enqueue(.init(roomID: "!a", text: "привет", accountID: "one"), in: defaults)

        ChatDirectory.forget(account: "one", in: defaults)

        #expect(ChatDirectory.directory(from: defaults).isEmpty)
        #expect(ChatDirectory.drainOutbox(from: defaults).isEmpty)
    }

    /// Nothing goes out from the wrong person: an account drains what it sends, and what somebody
    /// shared into another account's chat waits for that account.
    @Test("an account sends only its own messages, and the rest wait")
    func outboxIsDrainedPerAccount() throws {
        let defaults = try freshDefaults("outbox-accounts")
        ChatDirectory.enqueue(.init(roomID: "!a", text: "one's", accountID: "one"), in: defaults)
        ChatDirectory.enqueue(.init(roomID: "!b", text: "two's", accountID: "two"), in: defaults)
        ChatDirectory.enqueue(.init(roomID: "!c", text: "from before accounts"), in: defaults)

        #expect(ChatDirectory.accountsWaitingToSend(in: defaults) == ["one", "two"])

        let mine = ChatDirectory.drainOutbox(forAccount: "one", from: defaults)
        #expect(mine.map(\.text) == ["one's", "from before accounts"])
        #expect(ChatDirectory.accountsWaitingToSend(in: defaults) == ["two"])

        #expect(ChatDirectory.drainOutbox(forAccount: "two", from: defaults).map(\.text) == ["two's"])
        #expect(ChatDirectory.drainOutbox(from: defaults).isEmpty)
    }

    @Test("an open request says whose chat it is")
    func openRequestCarriesTheAccount() throws {
        let defaults = try freshDefaults("open-account")
        ChatDirectory.requestOpen(roomID: "!room", accountID: "two", in: defaults)

        let request = ChatDirectory.takePendingOpenRequest(from: defaults)
        #expect(request == .init(roomID: "!room", accountID: "two"))
        #expect(ChatDirectory.takePendingOpenRequest(from: defaults) == nil)
    }
}

/// The number on the icon, with more than one account adding to it.
@Suite
struct UnreadCountsTests {
    private func freshDefaults(_ name: String) -> UserDefaults? {
        let suite = "UnreadCountsTests.\(name)"
        UserDefaults().removePersistentDomain(forName: suite)
        return UserDefaults(suiteName: suite)
    }

    /// A push for one account carries that account's count, and used to be written straight onto
    /// the icon — taking it down to two while the other account had forty waiting.
    @Test("the icon is every account added together")
    func theIconIsTheSum() throws {
        let defaults = try freshDefaults("sum")
        UnreadCounts.set(40, forAccount: "one", in: defaults)
        let total = UnreadCounts.set(2, forAccount: "two", in: defaults)

        #expect(total == 42)
        #expect(UnreadCounts.count(forAccount: "one", in: defaults) == 40)
    }

    @Test("a signed-out account's count comes off the icon")
    func forgettingAnAccount() throws {
        let defaults = try freshDefaults("forget")
        UnreadCounts.set(40, forAccount: "one", in: defaults)
        UnreadCounts.set(2, forAccount: "two", in: defaults)

        #expect(UnreadCounts.forget(account: "one", in: defaults) == 2)
    }
}
