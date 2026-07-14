import Foundation
import Observation
import MatrixRustSDK

/// Something about the account that would not change. One case per act, for the same reason
/// `RoomActionFailure` has one: "something went wrong" leaves the user with nothing to do,
/// and the two failures here that a person can actually act on — a key that did not fit, a
/// picture the server refused — say so in different words because they call for different
/// things.
public enum AccountActionFailure: String, CaseIterable, ActionFailure, Error {
    case name
    case picture
    case protectHistory
    case newKey
    case restore

    public var id: String { rawValue }

    public var explanation: LocalizedStringResource {
        switch self {
        case .name: CoreStrings.Account.nameFailed
        case .picture: CoreStrings.Account.pictureFailed
        case .protectHistory: CoreStrings.Account.protectFailed
        case .newKey: CoreStrings.Account.newKeyFailed
        case .restore: CoreStrings.Account.restoreFailed
        }
    }
}

/// Whether this account's history survives losing this device — which is the only thing
/// about recovery a person needs to decide, and so it is the only thing this says.
///
/// The four cases are the SDK's `RecoveryState` with the cryptography taken out of the
/// names. `incomplete` is the one worth understanding: it means recovery is *on for the
/// account* but this device does not hold the key, so the old messages are on the server,
/// encrypted, and unreadable here until the key is typed in. That is not "off" — offering
/// to turn it on would quietly reset the backup and lose exactly what the user was trying
/// to get back.
public enum HistoryProtection: Sendable, Equatable {
    case unknown
    case on
    case off
    case keyNeeded
}

/// A recovery key, freshly minted, on its way to being shown once.
///
/// A type rather than a bare `String` so that it can be `Identifiable` and drive a sheet
/// directly. It is its own identity: two different keys are two different things to show,
/// and the same key shown twice is the same sheet.
public struct RecoveryKey: Identifiable, Sendable, Equatable {
    public let value: String
    public var id: String { value }
}

/// The state of this account's encryption, and the two things that can be done about it:
/// protect the history, or get it back.
///
/// A store of its own rather than more surface on `UserSession`, because everything here
/// is bought at the price of a request to the server and most sessions never open the
/// screen that shows it. `UserSession.recovery()` builds it when somebody looks.
@MainActor
@Observable
public final class RecoveryStore {
    public private(set) var protection: HistoryProtection = .unknown

    /// Whether this device is one the account trusts. Shown, not acted on: verifying a
    /// device against another one is a whole flow of its own, and this screen only says
    /// where things stand.
    public private(set) var isDeviceVerified = false

    /// True while a request is in flight. Every act here talks to the server and none of
    /// them is quick — enabling recovery uploads every room key this device holds.
    public private(set) var isWorking = false

    /// A recovery key that has just been made, and that the user has not yet been shown.
    ///
    /// It is held here, in memory, for exactly as long as the sheet showing it is open,
    /// and it is never written anywhere: the whole point of a recovery key is that the
    /// only copy is the one the person keeps. Storing it in the Keychain "for convenience"
    /// would put it on the device whose loss it exists to survive.
    ///
    /// `Identifiable` so the sheet can be driven by `.sheet(item:)` — presence *is* the
    /// presentation state, and the alternative is a hand-built binding that says
    /// `freshKey != nil` beside a body that unwraps the same optional a second time.
    public private(set) var freshKey: RecoveryKey?

    public var failure: AccountActionFailure?

    private let encryption: Encryption

    /// Kept alive because dropping it cancels the subscription. Recovery state changes
    /// under us — another device enabling backup flips this one from `off` to `keyNeeded`
    /// — and a screen showing the stale answer would offer the wrong button.
    private var subscription: TaskHandle?

    /// The same thing for whether the device is trusted, and it was missing.
    ///
    /// `isDeviceVerified` was read once, in `load`, and then believed forever — but the most
    /// common way for it to *become* true is the thing this very screen does: type the recovery
    /// key in. So the user typed the key, the history came back, and the screen went on saying
    /// "this device is not verified" underneath it. Leaving and coming back fixed it, which is the
    /// signature of a value that is fetched rather than watched.
    private var verification: TaskHandle?

    init(encryption: Encryption) {
        self.encryption = encryption
    }

    /// Called when the screen goes away. An explicit stop rather than a `deinit`, like
    /// `PinnedStore` — the handle is `@MainActor` state and `deinit` is not on the actor,
    /// so the tidy-looking version does not compile.
    public func stop() {
        subscription?.cancel()
        subscription = nil

        verification?.cancel()
        verification = nil
    }

    /// Reads where things stand, and subscribes so they stay read.
    ///
    /// Idempotent, because the screen calls it on every appearance and coming *back* to a
    /// screen is an appearance: without the guard, a push and a pop would tear the SDK
    /// listener down and register an identical one in its place, for state that had not
    /// moved.
    public func load() {
        guard subscription == nil else { return }

        protection = Self.protection(from: encryption.recoveryState())
        isDeviceVerified = encryption.verificationState() == .verified

        subscription = encryption.recoveryStateListener(listener: Updates { [weak self] state in
            Task { @MainActor in self?.protection = Self.protection(from: state) }
        })

        verification = encryption.verificationStateListener(listener: Verification { [weak self] state in
            Task { @MainActor in self?.isDeviceVerified = state == .verified }
        })
    }

    /// Turn recovery on: back the room keys up, and mint the key that unlocks them.
    ///
    /// `waitForBackupsToUpload` is true, and it has to be. The alternative returns a key
    /// the moment the backup *exists*, while the keys are still going up — and a person
    /// who writes that key down and immediately reinstalls the app gets back a fraction of
    /// their history and no explanation. Better to make them wait for the spinner.
    public func protectHistory() async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }

        do {
            let key = try await encryption.enableRecovery(waitForBackupsToUpload: true,
                                                         passphrase: nil,
                                                         progressListener: IgnoreProgress())
            freshKey = RecoveryKey(value: key)
            protection = .on
        } catch {
            Log.session.error("recovery would not turn on: \(error)")
            failure = .protectHistory
        }
    }

    /// Throw the old key away and make a new one. What you do when the paper it was written
    /// on is somewhere you would rather it were not.
    public func makeNewKey() async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }

        do {
            freshKey = RecoveryKey(value: try await encryption.resetRecoveryKey())
            protection = .on
        } catch {
            Log.session.error("the recovery key would not reset: \(error)")
            failure = .newKey
        }
    }

    /// Hand the key back to the SDK and let it unlock what is already on the server.
    public func restore(with key: String) async {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !isWorking else { return }

        isWorking = true
        defer { isWorking = false }

        do {
            try await encryption.recover(recoveryKey: key)
            protection = .on
        } catch {
            // Not logged with the key in it, obviously — it is the one string in this file
            // that is worth as much as the password.
            Log.session.error("the recovery key was refused: \(error)")
            failure = .restore
        }
    }

    /// Called when the sheet showing the key is dismissed. From then on the only copy is
    /// wherever the user put it, which is the arrangement.
    public func forgetFreshKey() {
        freshKey = nil
    }

    private static func protection(from state: RecoveryState) -> HistoryProtection {
        switch state {
        case .unknown: .unknown
        case .enabled: .on
        case .disabled: .off
        case .incomplete: .keyNeeded
        }
    }

    /// The SDK insists on being told how the upload is going; nothing on the screen says.
    /// A percentage on a progress bar that jumps from 0 to 100 in one step for a small
    /// account and crawls for a large one tells the user less than a plain spinner does.
    private final class IgnoreProgress: EnableRecoveryProgressListener {
        func onUpdate(status: EnableRecoveryProgress) {}
    }

    private final class Verification: VerificationStateListener {
        private let changed: @Sendable (VerificationState) -> Void

        init(_ changed: @escaping @Sendable (VerificationState) -> Void) {
            self.changed = changed
        }

        func onUpdate(status: VerificationState) {
            changed(status)
        }
    }

    private final class Updates: RecoveryStateListener {
        private let changed: @Sendable (RecoveryState) -> Void

        init(_ changed: @escaping @Sendable (RecoveryState) -> Void) {
            self.changed = changed
        }

        func onUpdate(status: RecoveryState) {
            changed(status)
        }
    }
}
