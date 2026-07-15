import Foundation
import Testing
@testable import IskraCore

/// When the app should close its own lock. Pure logic — no biometrics, no background, just the
/// question "given when it was last active and how long ago that was, is it locked now?".
@Suite("AppLock.shouldLock")
struct AppLockTests {
    private let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

    @Test("a disabled lock never locks")
    func disabledNeverLocks() {
        #expect(!AppLock.shouldLock(enabled: false, lastActive: now, now: now, timeout: .immediately))
        #expect(!AppLock.shouldLock(enabled: false, lastActive: nil, now: now, timeout: .afterFiveMinutes))
    }

    @Test("no record of leaving means lock — a cold launch cannot vouch for anyone")
    func noLastActiveLocks() {
        #expect(AppLock.shouldLock(enabled: true, lastActive: nil, now: now, timeout: .afterFiveMinutes))
    }

    @Test("immediately locks on any trip away")
    func immediatelyLocksAtOnce() {
        let aMomentAgo = now.addingTimeInterval(-1)
        #expect(AppLock.shouldLock(enabled: true, lastActive: aMomentAgo, now: now, timeout: .immediately))
    }

    @Test("within the grace period it stays open")
    func withinGraceStaysOpen() {
        let thirtySecondsAgo = now.addingTimeInterval(-30)
        #expect(!AppLock.shouldLock(enabled: true, lastActive: thirtySecondsAgo, now: now, timeout: .afterMinute))
    }

    @Test("past the grace period it locks")
    func pastGraceLocks() {
        let twoMinutesAgo = now.addingTimeInterval(-120)
        #expect(AppLock.shouldLock(enabled: true, lastActive: twoMinutesAgo, now: now, timeout: .afterMinute))
    }

    @Test("exactly at the boundary locks")
    func boundaryLocks() {
        let exactlyAMinuteAgo = now.addingTimeInterval(-60)
        #expect(AppLock.shouldLock(enabled: true, lastActive: exactlyAMinuteAgo, now: now, timeout: .afterMinute))
    }

    @Test("the five-minute grace holds for four minutes")
    func fiveMinuteGrace() {
        let fourMinutesAgo = now.addingTimeInterval(-240)
        #expect(!AppLock.shouldLock(enabled: true, lastActive: fourMinutesAgo, now: now, timeout: .afterFiveMinutes))
        let sixMinutesAgo = now.addingTimeInterval(-360)
        #expect(AppLock.shouldLock(enabled: true, lastActive: sixMinutesAgo, now: now, timeout: .afterFiveMinutes))
    }
}
