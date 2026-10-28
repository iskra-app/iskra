import Testing
import Foundation
@testable import IskraCore

/// What the server said, and who the app is willing to say it to.
///
/// Neither half needs a homeserver: one is a dictionary turned into a value, the other is two
/// booleans and the rule between them. The part that does need a homeserver — whether presence is
/// switched on at all — cannot be tested and is `--probe-presence` instead.
struct PresenceTests {
    // MARK: - Reading the answer

    @Test func lastActiveIsAnInstantAndNotAnAge() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let presence = Presence(json: ["presence": "offline", "last_active_ago": 300_000], now: now)

        // Five minutes, in milliseconds, turned into the moment it points at — at the moment the
        // answer arrived. Kept as an age it would silently stop ageing.
        #expect(presence.lastActive == now.addingTimeInterval(-300))
        #expect(presence.state == .offline)
    }

    @Test func aServerThatSaysNothingIsNotAServerSayingOffline() {
        // Exactly what a homeserver with presence disabled returns, for everybody, including
        // people who are typing at you right now. Drawing "не в сети" from it would be the app
        // stating something it has not been told.
        let silent = Presence(json: ["presence": "offline"])
        #expect(silent.lastActive == nil)
        #expect(!silent.isWorthShowing)

        let told = Presence(json: ["presence": "offline", "last_active_ago": 60_000])
        #expect(told.isWorthShowing)
    }

    @Test func onlineIsWorthShowingWithNoTimestampAtAll() {
        let presence = Presence(json: ["presence": "online", "currently_active": true])
        #expect(presence.isWorthShowing)
        #expect(presence.isCurrentlyActive)
    }

    @Test func anUnknownStateIsReadAsOffline() {
        // A server inventing a fourth state must not be read as "online".
        #expect(Presence(json: ["presence": "napping"]).state == .offline)
        #expect(Presence(json: [:]).state == .offline)
    }

    @Test func unavailableIsIdleAndNotAbsent() {
        let presence = Presence(json: ["presence": "unavailable", "last_active_ago": 900_000])
        #expect(presence.state == .unavailable)
        #expect(presence.isWorthShowing)
    }

    // MARK: - Who is looked at

    /// Hiding from people means not looking at them either — the rule `watchPresence` asks before
    /// every request, so no screen can watch while hiding.
    @Test func hidingYourOwnHidesEverybodyElses() throws {
        let name = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }

        #expect(PrivacySettings.seesOthersPresence(defaults))
        defaults.set(true, forKey: PrivacySettings.hidesPresenceKey)
        #expect(!PrivacySettings.seesOthersPresence(defaults))
    }
}
