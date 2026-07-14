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
    case startOver

    public var id: String { rawValue }

    public var explanation: LocalizedStringResource {
        switch self {
        case .name: CoreStrings.Account.nameFailed
        case .picture: CoreStrings.Account.pictureFailed
        case .protectHistory: CoreStrings.Account.protectFailed
        case .newKey: CoreStrings.Account.newKeyFailed
        case .restore: CoreStrings.Account.restoreFailed
        case .startOver: CoreStrings.Account.startOverFailed
        }
    }
}

/// What the server wants before it will let this account throw its encryption away and start again.
///
/// The answer is the server's, not ours — `IdentityResetHandle.authType()` — and the three cases are
/// the three shapes it comes in. It is carried up as a value rather than acted on down here for the
/// usual reason: opening a browser is not something `IskraCore` is allowed to do, and a URL is a fact
/// about the account rather than a screen.
public enum StartOverApproval: Sendable, Equatable {
    /// The server is satisfied already. Go straight on.
    case none
    /// The user must approve it on the server's own page, in a browser, and come back.
    case browser(URL)
    /// The server wants the account password typed in again.
    case password
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

    // MARK: - Minting a code
    //
    // Both of these *hand the code back* rather than parking it in a property on this store, and
    // that is the whole of how "shown exactly once" is enforced.
    //
    // It used to be a `freshKey` on the store, which was fine while the store was built by the one
    // screen that showed it and died with it. It is not fine now: this store belongs to the session,
    // so a code left on it outlives the screen that minted it, sits in memory as plaintext for the
    // rest of the sign-in, and — worse — is *shared*. Two screens bound sheets to the same optional.
    // Either could clear it out from under the other, and opening settings could pop up, unbidden, a
    // code that had already been shown and dealt with. A secret that is shown once must be owned by
    // whoever is showing it, and must die when they do.
    //
    // So the code goes straight to the caller, who holds it in view state for exactly as long as it
    // is on screen. Nothing here keeps a copy. It is never written to disk in any form: the Keychain
    // would put it on the very device whose loss it exists to survive.

    /// Turn recovery on: back the room keys up, and mint the code that unlocks them.
    ///
    /// `waitForBackupsToUpload` is true, and it has to be. The alternative returns a code
    /// the moment the backup *exists*, while the keys are still going up — and a person
    /// who writes that code down and immediately reinstalls the app gets back a fraction of
    /// their history and no explanation. Better to make them wait for the spinner.
    public func protectHistory() async -> RecoveryKey? {
        guard !isWorking else { return nil }
        isWorking = true
        defer { isWorking = false }

        do {
            let key = try await encryption.enableRecovery(waitForBackupsToUpload: true,
                                                         passphrase: nil,
                                                         progressListener: IgnoreProgress())
            protection = .on
            return RecoveryKey(value: key)
        } catch {
            Log.session.error("recovery would not turn on: \(Log.describe(error), privacy: .public)")
            failure = .protectHistory
            return nil
        }
    }

    /// Throw the old code away and make a new one. What you do when the paper it was written
    /// on is somewhere you would rather it were not — and the only answer to a code that was
    /// never saved, because the old one cannot be shown again by anybody, ever.
    public func makeNewKey() async -> RecoveryKey? {
        guard !isWorking else { return nil }
        isWorking = true
        defer { isWorking = false }

        do {
            let key = try await encryption.resetRecoveryKey()
            protection = .on
            return RecoveryKey(value: key)
        } catch {
            Log.session.error("the recovery code would not reset: \(Log.describe(error), privacy: .public)")
            failure = .newKey
            return nil
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
            Log.session.error("the recovery key was refused: \(Log.describe(error), privacy: .public)")
            failure = .restore
        }
    }

    // MARK: - The moment after signing in

    /// Waits until the SDK has finished working out what this device knows, and reads the answer.
    ///
    /// This is what makes the question askable at all. `recoveryState()` immediately after a sign-in
    /// is `.unknown` — not "off", not "on", *unknown* — because the SDK has not yet talked to the
    /// server about backups and cross-signing. A screen that branched on it a moment too early would
    /// send a user with a perfectly good backup down the "let's make you a new code" path and reset
    /// the very history they signed in to read.
    ///
    /// Unbounded on purpose, and called from a screen that shows a spinner while it runs: the caller
    /// decides how long it is prepared to wait, because the honest fallback is "let them into the app
    /// anyway", and that is a decision about a screen and not about an account.
    public func waitForSetup() async {
        await encryption.waitForE2eeInitializationTasks()

        load()

        // And read it again, because `load()` is idempotent: by the time we get here the session has
        // usually started and subscribed already, so `load()` was a no-op and the value it left
        // behind is the one from *before* the wait — which is the one thing we came here not to use.
        protection = Self.protection(from: encryption.recoveryState())
    }

    /// Whether the account has another device that could vouch for this one.
    ///
    /// Asked only when the user says they have lost the code, and never to decide whether to *offer*
    /// the comparison — the two ways in are equal, and hiding one of them because we peeked would be
    /// exactly the ranking this flow exists to avoid.
    ///
    /// `false` when the question cannot be answered. A wrong "no" sends the user to the honest dead
    /// end; a wrong "yes" sends them to a screen that waits forever for a device that is not there.
    public func hasOtherDevices() async -> Bool {
        do {
            return try await encryption.hasDevicesToVerifyAgainst()
        } catch {
            Log.session.error("could not ask whether other devices exist: \(Log.describe(error), privacy: .public)")
            return false
        }
    }

    // MARK: - Starting again from nothing

    /// The reset, once it is under way and waiting on the user. Held because the server's approval
    /// arrives in a *second* step — a browser round-trip, or a password — and the handle is what the
    /// two steps have in common.
    private var reset: IdentityResetHandle?

    /// Throws this account's encryption away: the backup, the secret storage, and the cross-signing
    /// identity underneath both.
    ///
    /// This is the bottom of the flow — the user has no code and no other device — and it is the one
    /// place `resetRecoveryKey()` would have been the obvious wrong answer. A device in that position
    /// is not verified and cannot reach the account's cross-signing keys, so it cannot *re-key* the
    /// secret storage; it has nothing to sign the new key with. There is no key to reset. The only
    /// honest move left is to declare a new identity and let the old history stay unreadable, which
    /// is what it is: encrypted with keys nobody holds any more.
    ///
    /// Two steps, because most servers want to see the user again before they allow it. This one
    /// starts it and reports what the server is asking for; `finishStartOver` is what completes it.
    public func beginStartOver() async throws(AccountActionFailure) -> StartOverApproval {
        do {
            let handle = try await encryption.resetIdentity()
            reset = handle

            switch handle?.authType() {
            case nil:
                // No handle at all: the SDK is telling us there is nothing to reset. Not a failure —
                // there is simply no identity in the way, and the caller may go on and make a key.
                return .none
            case .uiaa:
                return .password
            case let .oAuth(info):
                guard let url = URL(string: info.approvalUrl) else { throw AccountActionFailure.startOver }
                return .browser(url)
            }
        } catch {
            Log.session.error("the reset would not start: \(Log.describe(error), privacy: .public)")
            reset = nil
            throw .startOver
        }
    }

    /// Finishes the reset the server has now approved.
    ///
    /// The password is `nil` on every path but `.password` — and it is never logged, never stored, and
    /// goes straight back out of memory with the handle.
    public func finishStartOver(password: String? = nil, userID: String? = nil) async throws(AccountActionFailure) {
        guard let reset else {
            // `beginStartOver` returned `.none`: there was no identity to throw away. Nothing to do
            // here, and saying so is not a failure.
            return
        }

        self.reset = nil
        isWorking = true
        defer { isWorking = false }

        do {
            if let password, let userID {
                let details = AuthDataPasswordDetails(identifier: userID, password: password)
                try await reset.reset(auth: .password(passwordDetails: details))
            } else {
                try await reset.reset(auth: nil)
            }
        } catch {
            Log.session.error("the reset would not finish: \(Log.describe(error), privacy: .public)")
            throw .startOver
        }
    }

    /// Abandons a reset the user backed out of — they closed the browser, or thought better of it.
    /// The SDK is told, rather than left holding a flow nobody is going to finish.
    public func cancelStartOver() async {
        guard let reset else { return }
        self.reset = nil
        await reset.cancel()
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
