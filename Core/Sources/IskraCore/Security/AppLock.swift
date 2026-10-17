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
    /// came up — or that the trip it made has already been answered with a face.
    private var lastActive: Date?

    /// Whether the system's authentication sheet is up. While it is, the scene's comings and goings
    /// belong to that sheet and say nothing about the user leaving the app.
    private var isAuthenticating = false

    private let defaults: UserDefaults?

    private enum Keys {
        static let enabled = "appLock.enabled"
        static let timeout = "appLock.timeout"
        /// When the app last went to the background, written to the shared defaults so the
        /// notification extension — a separate process — can decide whether the app is locked and
        /// therefore whether a push may show its contents. See `isLockedNow`.
        static let lastActive = "appLock.lastActive"
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

    /// The app went to the background. Remember when — in memory, and in the shared defaults so the
    /// notification extension can read it — so `enteredForeground` and `isLockedNow` can both measure
    /// the trip.
    /// Deaf to the scene while the system's own authentication sheet is up. That sheet belongs to
    /// another process and takes the app off the screen to show itself, so the app is told it left
    /// and came back — a trip it never made, and one `immediately` would read as reason to lock
    /// again the instant the face was accepted.
    public func enteredBackground(now: Date = .now) {
        guard !isAuthenticating else { return }
        lastActive = now
        defaults?.set(now.timeIntervalSinceReferenceDate, forKey: Keys.lastActive)
    }

    /// The app came back. Lock if it was away long enough — see `shouldLock`.
    ///
    /// A return with no departure behind it locks nothing, and that guard is the whole of the
    /// unlock-relock loop. `shouldLock` reads a missing `lastActive` as "lock", which is right for
    /// the two places that ask it cold — a launch, and the notification extension, neither of which
    /// has anything to vouch for who is holding the phone — and wrong here, where the app has been
    /// on screen the whole time and no trip happened at all. Without it the shield comes down, the
    /// scene goes `.active`, there is no departure on record, so the shield goes straight back up
    /// and asks for the face again, for ever.
    public func enteredForeground(now: Date = .now) {
        guard !isAuthenticating, lastActive != nil else { return }
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

    /// Whether the lock is turned on at all, for a process that cannot ask whether it is closed right
    /// now — the widget, which is drawn ahead of time and shown for hours. A widget cannot know who
    /// will be looking at it, so with the lock on it shows nobody's face and nobody's name.
    nonisolated public static func isEnabled(defaults: UserDefaults?) -> Bool {
        defaults?.bool(forKey: Keys.enabled) ?? false
    }

    /// Whether the app is locked *from another process's point of view* — the notification
    /// extension's. It has no `AppLock` instance and no runtime `isLocked`; all it has is the shared
    /// defaults, so it reads the same three facts the app wrote there and runs the same `shouldLock`
    /// rule. A push arriving while this is true must not show its contents.
    ///
    /// Conservative when the settings are missing or unreadable: if the lock is on but there is no
    /// record of when the app was last active, it treats the app as locked — the honest default when
    /// nothing can vouch for who is holding the phone.
    nonisolated public static func isLockedNow(defaults: UserDefaults?, now: Date = .now) -> Bool {
        guard let defaults, defaults.bool(forKey: Keys.enabled) else { return false }
        let timeout = AppLockTimeout(rawValue: defaults.string(forKey: Keys.timeout) ?? "") ?? .immediately
        let stamp = defaults.object(forKey: Keys.lastActive) as? Double
        let lastActive = stamp.map { Date(timeIntervalSinceReferenceDate: $0) }
        return shouldLock(enabled: true, lastActive: lastActive, now: now, timeout: timeout)
    }

    /// Asks the system to prove it is the owner. On success the shield comes down. A failure or a
    /// cancel leaves it up — there is no other way past.
    public func authenticate(reason: String, now: Date = .now) async -> Bool {
        guard !isAuthenticating else { return false }
        let context = LAContext()
        var error: NSError?
        // `.deviceOwnerAuthentication` includes the passcode fallback, so this is available whenever
        // the device has *any* lock set — which, for a device holding someone's messages, it should.
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return false
        }

        isAuthenticating = true
        defer { isAuthenticating = false }

        do {
            let ok = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            if ok { didAuthenticate(now: now) }
            return ok
        } catch {
            return false
        }
    }

    /// The shield comes down, and the trip that closed it is spent.
    ///
    /// Forgetting `lastActive` is the point: it is the record of a departure, that departure has now
    /// been answered for, and leaving it behind would have the next `.active` measure the same trip
    /// a second time and lock again. The shared defaults are stamped with *now* instead, so the
    /// notification extension — which knows nothing but that stamp — sees an app in use rather than
    /// one still out of the room.
    /// Internal rather than private so the tests can walk the lock through an unlock without a face
    /// to show it — and internal rather than public so that nothing above `IskraCore`, which is to
    /// say no screen, can open the lock without going through the system.
    func didAuthenticate(now: Date) {
        isLocked = false
        lastActive = nil
        defaults?.set(now.timeIntervalSinceReferenceDate, forKey: Keys.lastActive)
    }

    /// Whether the device can authenticate at all — for the settings screen, which should not offer
    /// a lock the device cannot open.
    public var canAuthenticate: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }
}
