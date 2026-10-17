import Foundation
import Testing
@testable import IskraCore

@Suite("Thread settings")
struct ThreadSettingsTests {
    private func defaults() -> UserDefaults {
        let name = "ThreadSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test("by default, threads only in rooms of over a hundred, and replies stay in the room")
    func defaultsToLargeRooms() {
        let d = defaults()
        #expect(ThreadSettings.shown(d) == .inLargeRooms)
        #expect(!ThreadSettings.hidesReplies(d))
        #expect(!ThreadSettings.usesThreads(kind: .group, memberCount: 100, d))
        #expect(ThreadSettings.usesThreads(kind: .group, memberCount: 101, d))
    }

    @Test("a personal chat never has threads, even with “always”")
    func neverInPersonalChats() {
        #expect(!ThreadSettings.usesThreads(kind: .direct, memberCount: 2, shown: .always))
        #expect(ThreadSettings.usesThreads(kind: .group, memberCount: 3, shown: .always))
        #expect(!ThreadSettings.usesThreads(kind: .group, memberCount: 500, shown: .never))
    }

    @Test("the old toggle switched off reads as “never”, and the new choice wins over it")
    func legacyToggle() {
        let d = defaults()
        d.set(false, forKey: ThreadSettings.legacyIsEnabledKey)
        #expect(ThreadSettings.shown(d) == .never)
        d.set(ThreadSettings.Shown.always.rawValue, forKey: ThreadSettings.shownKey)
        #expect(ThreadSettings.shown(d) == .always)
    }
}
