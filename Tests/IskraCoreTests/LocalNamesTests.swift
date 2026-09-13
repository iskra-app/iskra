import Foundation
import Testing
@testable import IskraCore

/// What the user privately calls somebody, kept on this device and never sent.
///
/// The rules worth pinning are the ones that would be invisible if they broke: a blank field means
/// "use the real name" rather than "call them nothing", a rename that changes nothing must not wake
/// the app, and signing out must take every one of them with it — these are one person's notes
/// about the people they talk to, stored in the clear, and the next account on the device is
/// somebody else.
@Suite("LocalNames")
struct LocalNamesTests {
    /// A throwaway defaults, one per test, for the same reason `ChatDirectoryTests` has one: these
    /// run in parallel, and the real App Group is the user's own.
    private func freshDefaults(_ name: String) -> UserDefaults {
        let suite = "iskra.tests.localNames.\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test("a name given is a name given back")
    func roundTrips() {
        let defaults = freshDefaults("roundTrip")
        LocalNames.set("Мама", for: "!a", in: defaults)

        #expect(LocalNames.name(for: "!a", in: defaults) == "Мама")
        #expect(LocalNames.name(for: "!b", in: defaults) == nil)
    }

    /// Emptying the field is how the real name comes back — so a blank must not be stored as a
    /// name, or the header would go silently empty and there would be no way to type it out of.
    @Test("a blank name is an absence, not a name")
    func blankIsAbsence() {
        let defaults = freshDefaults("blank")
        LocalNames.set("Мама", for: "!a", in: defaults)

        LocalNames.set("   ", for: "!a", in: defaults)
        #expect(LocalNames.name(for: "!a", in: defaults) == nil)

        LocalNames.set("Мама", for: "!a", in: defaults)
        LocalNames.set(nil, for: "!a", in: defaults)
        #expect(LocalNames.name(for: "!a", in: defaults) == nil)
    }

    /// A stray space at the end of what was typed is not a different name, and storing one would
    /// make an invisible difference to a visible thing.
    @Test("the surrounding whitespace is not part of the name")
    func trims() {
        let defaults = freshDefaults("trim")
        LocalNames.set("  Аня ", for: "!a", in: defaults)
        #expect(LocalNames.name(for: "!a", in: defaults) == "Аня")
    }

    /// The rebuild of the chat list hangs off this notification, so an edit that changes nothing
    /// must not send one — leaving a field untouched would otherwise cost a pass over every room.
    @Test("only a real change is announced")
    func announcesOnlyRealChanges() {
        let defaults = freshDefaults("announce")
        // A room ID of this suite's own, counted under a lock: the notification centre is the
        // process's, every test in this file posts to it, and they all run at once.
        let roomID = "!announce:test"
        let announcements = Counter()

        let token = NotificationCenter.default.addObserver(forName: LocalNames.didChange,
                                                          object: nil,
                                                          queue: nil) { note in
            guard note.userInfo?["roomID"] as? String == roomID else { return }
            announcements.increment()
        }
        defer { NotificationCenter.default.removeObserver(token) }

        LocalNames.set("Мама", for: roomID, in: defaults)
        LocalNames.set("Мама", for: roomID, in: defaults)
        LocalNames.set("Мама ", for: roomID, in: defaults)
        #expect(announcements.value == 1)

        LocalNames.set(nil, for: roomID, in: defaults)
        #expect(announcements.value == 2)
    }

    /// How many times something happened, counted from whichever thread it happened on.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func increment() {
            lock.withLock { count += 1 }
        }

        var value: Int { lock.withLock { count } }
    }

    /// Signing out destroys the keys, the tokens and the store. These have to go with them: they
    /// are keyed by room ID, so a name left behind would reattach itself to the same room under a
    /// different account — somebody else's nickname for whoever is in it.
    @Test("signing out forgets every one of them")
    func forgetsEverything() {
        let defaults = freshDefaults("forget")
        LocalNames.set("Мама", for: "!a", in: defaults)
        LocalNames.set("Аня", for: "!b", in: defaults)

        LocalNames.forget(in: defaults)

        #expect(LocalNames.name(for: "!a", in: defaults) == nil)
        #expect(LocalNames.name(for: "!b", in: defaults) == nil)
    }

    /// The lock screen is the one place a nickname is most wanted and most easily forgotten: the
    /// notification is written by a second process that never sees the chat list. A renamed chat
    /// takes the title outright and drops the sender line, because in a personal chat the sender
    /// *is* the chat — printing «Мама» over `anna_1987` would undo the rename on the one screen
    /// the user cannot open to fix it.
    @Test("a renamed chat is renamed on the lock screen too")
    func pushUsesTheLocalName() {
        let renamed = PushMapper.attribution(roomName: "anna_1987",
                                             senderName: "anna_1987",
                                             isDirect: true,
                                             localName: "Мама")
        #expect(renamed.title == "Мама")
        #expect(renamed.sender == nil)

        // And a chat with no nickname is untouched — the rule above must not change the answer
        // for every other notification the app writes.
        let plain = PushMapper.attribution(roomName: "Кухня", senderName: "Аня", isDirect: false)
        #expect(plain.title == "Кухня")
        #expect(plain.sender == "Аня")
    }
}
