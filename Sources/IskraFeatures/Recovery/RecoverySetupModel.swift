import Foundation
import Observation
import IskraCore

/// The step between signing in and reading your messages.
///
/// It exists because the app did not have one, and the hole was exactly where a person falls into
/// it. Signing in on a second phone went straight to the conversations — where the old messages were
/// there, and unreadable, and nothing on the screen said why or offered to fix it. The only way out
/// was to guess that Settings held an encryption screen and go and find it. Nobody guesses that.
///
/// The whole flow speaks one word. Not *verification*, not *cross-signing*, not *secret storage* —
/// a **recovery code**, which behaves like a backup code from an authenticator app, a thing people
/// have already met. Everything the cryptography actually does is arranged behind that one idea, and
/// this type is the arranging.
///
/// Three ways through, and which one you get is decided by a single question — does this account
/// have a backup, and does *this device* hold the code to it:
///
///   - **No backup at all** (a new account): make one, without asking, and show the code once.
///   - **A backup this device cannot open**: two ways in, of equal weight — type the code, or hold
///     this device up to one that is already trusted.
///   - **Neither of those is possible**: say so plainly, throw the old encryption away, and start
///     again with a clean history. This is the branch that is easiest to get wrong; see `startOver`.
@MainActor
@Observable
public final class RecoverySetupModel {
    public enum Step: Equatable {
        /// Asking the SDK what this device knows. Brief, and never skipped: the answer is not
        /// available the instant a sign-in lands.
        case preparing
        /// Making the backup and minting the first code. Slow, and honestly so.
        case creating
        /// The code is on screen, for the only time it ever will be.
        case code
        /// Two ways in, neither of them the recommended one.
        case choose
        /// Typing the code.
        case entering
        /// The code is gone. What now depends on whether another device exists.
        case lost
        /// Throwing the old encryption away.
        case startingOver
        /// The server wants the account password before it will allow that.
        case password
        /// Out of the way — the conversations are next.
        case done
    }

    public private(set) var step: Step = .preparing

    /// What to do once a device has been confirmed against another one, which is a thing that can
    /// happen at two different moments in this flow and means two different things.
    ///
    /// Confirming from `choose` is the end of the story: the keys arrive on their own and the old
    /// messages open. Confirming from `lost` is the *middle* of one — the user got in, but the code
    /// they were supposed to be keeping is still lost, so a new one has to replace it before they
    /// are let go.
    private enum AfterConfirming {
        case finish
        case mintNewCode
    }

    private var afterConfirming: AfterConfirming = .finish

    /// What is being typed. Neither is ever logged, and the password is cleared the moment it has
    /// been spent — see `finishStartOver`.
    public var typedCode = ""
    public var password = ""

    /// Whether the account has another device that could vouch for this one. Asked once, when the
    /// user says the code is lost, and never before: peeking earlier in order to hide one of the two
    /// equal buttons is precisely the ranking this flow exists to refuse.
    public private(set) var hasOtherDevices = false

    public var failure: AccountActionFailure?

    /// Set when the user skipped saving the code, so the room list can nag them about it for as long
    /// as it is true. Read by `RecoveryBanner`; written here because this is the only place a code is
    /// ever shown, and therefore the only place one can be skipped.
    public private(set) var didSkipSavingCode = false

    /// Why this flow was opened, which decides where it starts.
    ///
    /// The banner is the reason this is a parameter rather than always "wherever the account happens
    /// to be". Somebody whose code is merely *unsaved* has an account in perfect order — `.on`, with
    /// a backup, with nothing to fix — so asking where the account stands would route them straight
    /// to `.done` and the banner they just tapped would do nothing at all. What they need is a new
    /// code, and the only way to get one is to make one: the old code cannot be shown again, by
    /// anybody, ever.
    /// `Identifiable` so that the room list's banner can drive the sheet with `.sheet(item:)`: the
    /// reason the banner was tapped *is* the presentation state, and there is nothing to keep in step.
    public enum Entry: Identifiable, Equatable {
        /// Just signed in: ask the account where it stands and go there.
        case afterSignIn
        /// The code was never saved. Replace it — see above for why "show it again" is not on offer.
        case makeNewCode

        public var id: Self { self }
    }

    private let entry: Entry

    public let session: UserSession

    private var recovery: RecoveryStore { session.recovery }
    public var verification: VerificationStore { session.verification }

    /// The code just minted, for exactly as long as it is on screen, and held *here* — by the thing
    /// that is showing it — rather than on the session's store where it used to live.
    ///
    /// That is the difference between a secret shown once and a secret shown whenever a screen
    /// happens to be built. The store is the session's and outlives every screen; a code parked on
    /// it sat in memory for the rest of the sign-in and could be picked up and presented a second
    /// time by an entirely different view. This model dies with the flow, and the code dies with it.
    ///
    /// Never written anywhere — not to the Keychain, which is on the device this code exists to
    /// survive the loss of, and not to disk in any other form. The only durable copy is the one the
    /// person makes.
    public private(set) var code: RecoveryKey?

    public var isWorking: Bool { recovery.isWorking }

    public init(session: UserSession, entry: Entry = .afterSignIn) {
        self.session = session
        self.entry = entry
    }

    /// Where a given state of the account sends the user.
    ///
    /// Pulled out as a function of its argument so that it can be *tested*, which almost nothing else
    /// in this type can be: every other path needs a live server, an encrypted store and a second
    /// device, and `swift test` has none of the three. It is also the one decision here that would be
    /// catastrophic to get backwards — routing an account that has a perfectly good backup into
    /// `.creating` would reset that backup and destroy exactly the history the user signed in to read.
    nonisolated static func route(for protection: HistoryProtection) -> Step {
        switch protection {
        case .off: .creating
        case .keyNeeded: .choose

        // `.on` needs nothing. `.unknown` is the SDK saying it does not know, and the one thing not
        // to do with "I don't know" is to act on it: letting the user into the app is recoverable —
        // the banner is still there, settings are still there — and guessing is not.
        case .on, .unknown: .done
        }
    }

    /// Finds out where this account stands, and goes there.
    public func begin() async {
        if entry == .makeNewCode {
            await mintNewCode()
            return
        }

        // Bounded, because the alternative is a person held in front of a spinner by a server that
        // has stopped answering. Letting them into the app on a timeout is the safe failure: the
        // conversations may be locked, but the banner and the settings screen are both still there,
        // and both still work.
        do {
            try await withTimeout(.seconds(30)) { [recovery] in
                await recovery.waitForSetup()
            }
        } catch {
            Log.session.error("gave up waiting for the account's encryption to settle")
            step = .done
            return
        }

        step = Self.route(for: recovery.protection)

        if step == .creating {
            await create()
        }
    }

    // MARK: - Flow 1 — a new account

    /// Turns the backup on and mints the first code, without asking anybody anything.
    ///
    /// Deliberately not a question. There is no version of "would you like your messages to survive
    /// your phone falling in a river" that a person answers *no* to on purpose, and asking it at the
    /// one moment they are trying to get into the app is how it gets answered no by accident.
    private func create() async {
        guard let minted = await recovery.protectHistory() else {
            // It did not work, and there is nothing here for the user to do about it. They are let
            // into the app; the banner will keep asking, and the settings screen can try again.
            failure = recovery.failure
            step = .done
            return
        }

        code = minted
        step = .code
    }

    /// The user says they have written the code down. Taken at their word — there is nothing to check
    /// it against, and a fake "confirm the code" step would only teach people to copy and paste.
    public func savedCode() {
        didSkipSavingCode = false
        forget()
    }

    /// The user has skipped it. Allowed — the design note allows it — and remembered, because a code
    /// that was never saved is a code that is gone, and they will find that out in six months from a
    /// screen that cannot help them. The banner is what stands between them and that.
    public func skippedCode() {
        didSkipSavingCode = true
        forget()
    }

    /// The code leaves memory the moment it leaves the screen, whichever of the two buttons took it
    /// there. From here on the only copy is wherever the person put it, which is the arrangement.
    private func forget() {
        code = nil
        step = .done
    }

    // MARK: - Flow 2 — a device that cannot read the history

    public func chooseCode() {
        step = .entering
    }

    /// Hands the typed code to the SDK.
    public func unlock() async {
        await recovery.restore(with: typedCode)

        if recovery.protection == .on {
            typedCode = ""
            step = .done
        } else {
            // The failure alert says what happened, and "I can't find my code" is still on screen
            // underneath it — which is the whole point of leaving the step where it is.
            failure = recovery.failure
        }
    }

    /// Asks another device to vouch for this one. The picture-comparison sheet takes it from here.
    public func confirmFromAnotherDevice() async {
        afterConfirming = .finish
        await verification.start()
    }

    /// A comparison finished. What that means depends on where it was started from.
    public func confirmed() async {
        switch afterConfirming {
        case .finish:
            step = .done

        case .mintNewCode:
            // They got in, but the code they lost is still lost — and it cannot be shown again, ever.
            // A new one has to take its place before they are let go, or the next new device lands
            // them right back here with nothing.
            await mintNewCode()
        }
    }

    /// Throws the old code away and makes one to replace it.
    ///
    /// The only answer to "I lost my code", and the only answer to "I never saved it" — because both
    /// of those are the same sentence to the secret storage this hangs off: the code is gone, and no
    /// part of this system can produce it again. Not the app, not the server, not the SDK. Making a
    /// new one is not the convenient option; it is the only one there is.
    private func mintNewCode() async {
        guard let minted = await recovery.makeNewKey() else {
            failure = recovery.failure
            step = .done
            return
        }

        code = minted
        step = .code
    }

    // MARK: - Flow 3 — the code is gone

    public func lostTheCode() async {
        hasOtherDevices = await recovery.hasOtherDevices()
        step = .lost
    }

    /// The way back for somebody who lost the code but still has a device that is trusted.
    public func recoverWithAnotherDevice() async {
        afterConfirming = .mintNewCode
        await verification.start()
    }

    /// Throws this account's encryption away and starts again with an empty history.
    ///
    /// The bottom of the flow, and the one place where the obvious call is the wrong one. A device
    /// with no code and no sibling is not trusted and cannot reach the account's cross-signing keys —
    /// so it cannot *re-key* the secret storage, because it has nothing to sign a new key with.
    /// `resetRecoveryKey()` has no key to reset. The only move left is to declare a new identity and
    /// let the old history stay where it is: on the server, encrypted, with nobody holding the keys.
    ///
    /// Most servers want to watch the user approve that on their own page before allowing it, which
    /// is why this is three steps and a browser rather than one call.
    public func startOver() async {
        step = .startingOver

        do {
            switch try await recovery.beginStartOver() {
            case .none:
                await finishStartOver()

            case let .browser(url):
                await WebAuthentication.approve(url: url)
                await finishStartOver()

            case .password:
                step = .password
            }
        } catch {
            failure = error as? AccountActionFailure ?? .startOver
            step = .lost
        }
    }

    /// The server asked for the password, and it has been typed.
    public func confirmWithPassword() async {
        step = .startingOver
        await finishStartOver(password: password)
    }

    private func finishStartOver(password: String? = nil) async {
        do {
            try await recovery.finishStartOver(password: password, userID: session.userID)
        } catch {
            self.password = ""
            failure = error as? AccountActionFailure ?? .startOver
            step = .lost
            return
        }

        // The password has done its job, and this is the moment it stops being needed.
        self.password = ""

        // The identity is new and there is no backup behind it. Making one now is not an extra — it
        // is the difference between "start fresh" and "start fresh and be in exactly this position
        // again on the next device".
        await create()
    }
}
