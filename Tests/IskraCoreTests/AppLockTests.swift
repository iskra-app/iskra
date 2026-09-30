import Foundation
import Testing
@testable import IskraCore

/// When the app should close its own lock. Pure logic — no biometrics, no background, just the
/// question "given when it was last active and how long ago that was, is it locked now?".
@Suite("AppLock.shouldLock")
struct AppLockTests {
    private let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

    @Test("a disabled lock never locks")
    func disabledNeverLocks() throws {
        #expect(!AppLock.shouldLock(enabled: false, lastActive: now, now: now, timeout: .immediately))
        #expect(!AppLock.shouldLock(enabled: false, lastActive: nil, now: now, timeout: .afterFiveMinutes))
    }

    @Test("no record of leaving means lock — a cold launch cannot vouch for anyone")
    func noLastActiveLocks() throws {
        #expect(AppLock.shouldLock(enabled: true, lastActive: nil, now: now, timeout: .afterFiveMinutes))
    }

    @Test("immediately locks on any trip away")
    func immediatelyLocksAtOnce() throws {
        let aMomentAgo = now.addingTimeInterval(-1)
        #expect(AppLock.shouldLock(enabled: true, lastActive: aMomentAgo, now: now, timeout: .immediately))
    }

    @Test("within the grace period it stays open")
    func withinGraceStaysOpen() throws {
        let thirtySecondsAgo = now.addingTimeInterval(-30)
        #expect(!AppLock.shouldLock(enabled: true, lastActive: thirtySecondsAgo, now: now, timeout: .afterMinute))
    }

    @Test("past the grace period it locks")
    func pastGraceLocks() throws {
        let twoMinutesAgo = now.addingTimeInterval(-120)
        #expect(AppLock.shouldLock(enabled: true, lastActive: twoMinutesAgo, now: now, timeout: .afterMinute))
    }

    @Test("exactly at the boundary locks")
    func boundaryLocks() throws {
        let exactlyAMinuteAgo = now.addingTimeInterval(-60)
        #expect(AppLock.shouldLock(enabled: true, lastActive: exactlyAMinuteAgo, now: now, timeout: .afterMinute))
    }

    @Test("the five-minute grace holds for four minutes")
    func fiveMinuteGrace() throws {
        let fourMinutesAgo = now.addingTimeInterval(-240)
        #expect(!AppLock.shouldLock(enabled: true, lastActive: fourMinutesAgo, now: now, timeout: .afterFiveMinutes))
        let sixMinutesAgo = now.addingTimeInterval(-360)
        #expect(AppLock.shouldLock(enabled: true, lastActive: sixMinutesAgo, now: now, timeout: .afterFiveMinutes))
    }
}

/// The lock as it behaves over a run of the app, rather than as one pure question. It is the
/// *sequence* — launch, unlock, scene active again — that span in a loop on the device, and no
/// test of `shouldLock` on its own could have caught it.
@MainActor
@Suite("AppLock over a session")
struct AppLockSessionTests {
    private let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

    /// A throwaway suite each time, so nothing here touches the real settings.
    private func lock(enabled: Bool = true, timeout: AppLockTimeout = .immediately) throws -> AppLock {
        let defaults = try #require(UserDefaults(suiteName: "AppLockTests.\(UUID().uuidString)"))
        defaults.set(enabled, forKey: "appLock.enabled")
        defaults.set(timeout.rawValue, forKey: "appLock.timeout")
        return AppLock(defaults: defaults)
    }

    @Test("a launch with the lock on starts locked")
    func launchesLocked() throws {
        #expect(try lock().isLocked)
        #expect(try !lock(enabled: false).isLocked)
    }

    @Test("unlocking on a cold launch survives the scene going active again")
    func unlockDoesNotLoop() throws {
        let appLock = try lock()
        // The system's sheet takes the app off screen and hands it straight back, so `.active`
        // arrives with no trip to the background behind it. This is the loop: it used to lock again
        // here, the instant the face was accepted, and then ask for the face again.
        appLock.didAuthenticate(now: now)
        appLock.enteredForeground(now: now.addingTimeInterval(1))
        #expect(!appLock.isLocked)
    }

    @Test("coming back from a real trip away still locks")
    func realTripStillLocks() throws {
        let appLock = try lock()
        appLock.didAuthenticate(now: now)
        appLock.enteredBackground(now: now.addingTimeInterval(10))
        appLock.enteredForeground(now: now.addingTimeInterval(20))
        #expect(appLock.isLocked)
    }

    @Test("a trip inside the grace period does not lock")
    func graceHolds() throws {
        let appLock = try lock(timeout: .afterMinute)
        appLock.didAuthenticate(now: now)
        appLock.enteredBackground(now: now.addingTimeInterval(10))
        appLock.enteredForeground(now: now.addingTimeInterval(20))
        #expect(!appLock.isLocked)
    }

    @Test("the same trip away is not counted twice")
    func tripIsSpentOnUnlock() throws {
        let appLock = try lock()
        appLock.enteredBackground(now: now)
        appLock.enteredForeground(now: now.addingTimeInterval(5))
        #expect(appLock.isLocked)
        appLock.didAuthenticate(now: now.addingTimeInterval(6))
        appLock.enteredForeground(now: now.addingTimeInterval(7))
        #expect(!appLock.isLocked)
    }
}
