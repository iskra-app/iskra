import Foundation
import Observation
import LocalAuthentication

/// How long the app may sit in the background before it locks itself.
///
/// The values are the ones a person thinks in — at once, after a minute, after five — not raw
/// seconds. `immediately` is zero, so leaving the app at all locks it; the others give a grace
/// period for the glance-at-another-app-and-come-back that should not cost a face scan.
public enum AppLockTimeout: String, CaseIterable, Sendable, Identifiable {
    case immediately
    case afterMinute
    case afterFiveMinutes

    public var id: String { rawValue }

    /// The grace period in seconds. `immediately` is zero.
    public var interval: TimeInterval {
        switch self {
        case .immediately: 0
        case .afterMinute: 60
        case .afterFiveMinutes: 5 * 60
        }
    }
}

/// The lock over the whole app: Face ID, Touch ID, or the device passcode, asked for on launch and
/// on coming back from the background after the chosen grace period.
///
/// It authenticates with `.deviceOwnerAuthentication` rather than the biometrics-only policy, on
/// purpose: that one falls back to the device passcode when a face is not recognised or the device
/// has no biometry at all, so there is always a way in and it is the *device's* passcode — stronger
/// than an app PIN and nothing for this app to store. (An app-specific PIN could be layered on later;
/// the device passcode is the safer default, and it is what "or a passcode" means here.)
///
/// The decision to lock is a pure function of when the app was last active, the clock, and the
/// timeout — `shouldLock` — so it can be pinned in tests without a clock or a background.
@MainActor
@Observable
public final class AppLock {
    /// Whether the lock is switched on at all. Persisted, so it survives a relaunch.
    public var isEnabled: Bool {
        didSet { defaults?.set(isEnabled, forKey: Keys.enabled) }
    }

    /// How long a trip to the background is forgiven before the lock closes.
    public var timeout: AppLockTimeout {
        didSet { defaults?.set(timeout.rawValue, forKey: Keys.timeout) }
    }

    /// Whether the app is locked *right now* and the shield should be up.
    public private(set) var isLocked: Bool

    /// When the app was last in the foreground, set as it leaves. Nil means it has not left since it
    /// came up.
    private var lastActive: Date?

    private let defaults: UserDefaults?

    private enum Keys {
        static let enabled = "appLock.enabled"
        static let timeout = "appLock.timeout"
    }

    /// - Parameter defaults: where the settings live. The app hands in the App-Group suite so the
    ///   choice is one the notification extension can also read; tests hand in a throwaway.
    public init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
        let enabled = defaults?.bool(forKey: Keys.enabled) ?? false
        self.isEnabled = enabled
        self.timeout = defaults.flatMap { AppLockTimeout(rawValue: $0.string(forKey: Keys.timeout) ?? "") }
            ?? .immediately
        // Launching counts as coming back cold: if the lock is on, it is closed until the first
        // unlock. Nothing that happened before this launch can vouch for who is holding the phone.
        self.isLocked = enabled
    }

    /// The app went to the background. Remember when, so `enteredForeground` can measure the trip.
    public func enteredBackground(now: Date = .now) {
        lastActive = now
    }

    /// The app came back. Lock if it was away long enough — see `shouldLock`.
    public func enteredForeground(now: Date = .now) {
        if Self.shouldLock(enabled: isEnabled, lastActive: lastActive, now: now, timeout: timeout) {
            isLocked = true
        }
    }

    /// Whether the app should be locked, given how long it was away. Pure, and the whole of the
    /// locking rule: on when enabled and either it was never seen to leave-and-return within the
    /// grace period, or the grace period has elapsed. `immediately` (zero) locks on any trip away.
    nonisolated public static func shouldLock(enabled: Bool,
                                              lastActive: Date?,
                                              now: Date,
                                              timeout: AppLockTimeout) -> Bool {
        guard enabled else { return false }
        guard let lastActive else { return true }
        return now.timeIntervalSince(lastActive) >= timeout.interval
    }

    /// Asks the system to prove it is the owner. On success the shield comes down. A failure or a
    /// cancel leaves it up — there is no other way past.
    public func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        // `.deviceOwnerAuthentication` includes the passcode fallback, so this is available whenever
        // the device has *any* lock set — which, for a device holding someone's messages, it should.
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return false
        }

        do {
            let ok = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            if ok { isLocked = false }
            return ok
        } catch {
            return false
        }
    }

    /// Whether the device can authenticate at all — for the settings screen, which should not offer
    /// a lock the device cannot open.
    public var canAuthenticate: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }
}
