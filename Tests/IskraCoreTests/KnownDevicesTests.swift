import Foundation
import Testing
@testable import IskraCore

/// What counts as a new sign-in. The banner it drives sits at the top of the chat list and says
/// "somebody may be in your account" — so the two ways to get it wrong are both bad: crying wolf over
/// sessions somebody always had, and staying quiet about one that is new.
@Suite("Known devices")
struct KnownDevicesTests {
    private func fresh(_ name: String) throws -> KnownDevices {
        let suite = "iskra.tests.knownDevices.\(name)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return KnownDevices(defaults: defaults)
    }

    private func device(_ id: String, current: Bool = false) -> AccountDevice {
        AccountDevice(id: id, name: nil, lastSeenIP: nil, lastSeenAt: nil, isCurrent: current)
    }

    @Test("the first look asks about nothing and remembers everything")
    func firstLookIsQuiet() throws {
        let known = try fresh("first")
        let list = [device("ME", current: true), device("OLD")]
        #expect(known.newSessions(in: list, account: "A").isEmpty)
        #expect(known.newSessions(in: list, account: "A").isEmpty)
    }

    @Test("a session that appears later is new until confirmed")
    func laterSessionIsNew() throws {
        let known = try fresh("later")
        _ = known.newSessions(in: [device("ME", current: true), device("OLD")], account: "A")

        let list = [device("ME", current: true), device("OLD"), device("STRANGER")]
        #expect(known.newSessions(in: list, account: "A").map(\.id) == ["STRANGER"])
        #expect(known.newSessions(in: list, account: "A").map(\.id) == ["STRANGER"])

        known.confirm("STRANGER", for: "A")
        #expect(known.newSessions(in: list, account: "A").isEmpty)
    }

    @Test("this device is never news, even when it was not known")
    func currentIsNeverNew() throws {
        let known = try fresh("current")
        _ = known.newSessions(in: [device("OLD")], account: "A")
        #expect(known.newSessions(in: [device("ME", current: true), device("OLD")], account: "A").isEmpty)
    }

    @Test("each account keeps its own memory, and forgetting one leaves the other")
    func perAccount() throws {
        let known = try fresh("accounts")
        _ = known.newSessions(in: [device("X")], account: "A")
        // B has never been looked at: its first look is quiet too, whatever A knows.
        #expect(known.newSessions(in: [device("Y")], account: "B").isEmpty)

        known.forget(account: "A")
        #expect(known.newSessions(in: [device("Z")], account: "A").isEmpty)
        #expect(known.newSessions(in: [device("Y"), device("W")], account: "B").map(\.id) == ["W"])
    }
}
