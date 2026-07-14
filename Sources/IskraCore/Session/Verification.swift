import Foundation
import Observation
import MatrixRustSDK

/// Proving that a device is really yours, by comparing pictures with a device that already is —
/// in both directions: this device asking to be trusted, and this device being asked to trust
/// another.
///
/// This is the hole the audit found in the middle of an end-to-end encrypted messenger, and it was
/// a hole of a particular kind: the app *told people to do this*. A message that would not send
/// said "verify this device — it's done in settings", and in settings there was a line saying
/// "Not verified" and no way whatsoever to change it. The instruction led to a wall.
///
/// What it is *for* is worth stating plainly, because the cryptography is not the point and the
/// screen must never make it sound like it is. A new device has its own keys, and nobody — not the
/// server, not the people you talk to, not your other phone — has any reason to believe those keys
/// are yours rather than somebody else's who has taken your password. Verification is the moment
/// you tell your own account "this one is me", and you do it by looking at seven little pictures on
/// two screens at once, because that is the one channel an attacker in the middle cannot forge:
/// they are derived from a secret the two devices worked out together, and a device that is not in
/// the conversation cannot produce the same seven.
///
/// So the sequence, and every step of it is the SDK's:
///
///   1. `requestDeviceVerification()` — ask the account's other devices to look at this one.
///   2. Somebody accepts on the other side → `didAcceptVerificationRequest`.
///   3. `startSasVerification()` — turn the request into the short-authentication-string flow.
///   4. `didReceiveVerificationData` hands over the emoji.
///   5. The user says whether they match: `approveVerification()` or `declineVerification()`.
///   6. `didFinish` — the account now trusts this device, and the keys to the history follow.
///
/// And the same thing seen from the other end, which is the half that used to be missing:
///
///   1. `didReceiveVerificationRequest` — a device of yours is asking to be trusted.
///   2. The user is shown *which* device, and answers. There is no automatic yes; see below.
///   3. `acknowledgeVerificationRequest` makes it the live one, `acceptVerificationRequest` agrees.
///   4. From there it is steps 4–6 above, unchanged: the pictures arrive and a person compares them.
///
/// The two halves meet at `didAcceptVerificationRequest`, which the SDK sends to *both* sides when
/// the request goes ready — so exactly one of them must be the one to start the comparison, or both
/// send `m.key.verification.start` and the protocol has to break the tie. The side that *asked*
/// starts it (`isIncoming == false`); the side that *agreed* waits, and the SDK accepts the
/// incoming start for it and reports `didStartSasVerification`. That is the whole reason
/// `isIncoming` exists.
///
/// Nothing here is cryptography written in Swift, and nothing here may become that. The emoji are
/// the SDK's, the comparison is the SDK's, and this type is a state machine and a list of pictures.
///
/// It is owned by `UserSession` and lives as long as the sign-in does — *not* built by the screen
/// that shows it, which is what it used to be. A store that exists only while the encryption screen
/// is open is a store whose delegate is registered only while the encryption screen is open, and a
/// request that arrives at any other moment lands on nobody. Incoming verification is not something
/// the user goes to a screen to wait for; it is something that happens to them while they are
/// reading a chat.
@MainActor
@Observable
public final class VerificationStore {
    /// A device of yours, asking to be trusted.
    ///
    /// The device *name* is what the user is actually being asked about — "iPhone 15" is a thing a
    /// person can recognise or fail to recognise, and that recognition is the entire security of
    /// this step. The ID is carried too, and shown underneath, because names are chosen by whoever
    /// set the device up and two of them can read the same.
    public struct IncomingRequest: Sendable, Equatable, Identifiable {
        public let flowID: String
        public let senderID: String
        public let deviceID: String
        public let deviceName: String?

        public var id: String { flowID }
    }

    public enum Step: Sendable, Equatable {
        /// Nothing started.
        case idle
        /// Somebody else's device is asking to be trusted, and the user has not answered yet.
        /// The device in question is in `incoming`.
        case asked
        /// The user said yes to an incoming request and the two devices are working out the
        /// pictures. Seconds, normally — but a spinner with no words is how an app admits it does
        /// not know what it is doing.
        case negotiating
        /// Asked, and waiting for somebody to notice on the other device.
        case waitingForOtherDevice
        /// The pictures are on screen and the user is being asked whether they match.
        case comparing([String])
        case succeeded
        /// It went wrong — the other side never answered, or the flow broke.
        case failed
        /// Somebody said no: either the user here pressed "they don't match", or the other side
        /// backed out. Kept apart from `failed` because it is not a fault, and the two want
        /// different words: one is "try again", the other is "somebody stopped this on purpose,
        /// and if it was not you, do not trust this device".
        case declined
        /// The user was asked to trust a device and said it was not theirs. Kept apart from
        /// `declined` because the two mean opposite things about the user's safety: declining a
        /// mismatch is a verification that did not happen, and refusing an unrecognised device is
        /// a report that *somebody else is signing in with your password*. The words that follow
        /// are not the same words, and they should not be.
        case refused
    }

    public private(set) var step: Step = .idle {
        didSet {
            // A new question deserves fresh buttons. Every answer moves the step — accepting goes
            // to `.negotiating`, declining to `.declined`, approving eventually to `.succeeded` —
            // so this is exactly the moment `hasAnswered` stops being true.
            if step != oldValue { hasAnswered = false }
        }
    }

    /// The device asking to be trusted, for as long as that conversation is on screen — through
    /// the question, the pictures and the outcome, because it is the same sheet throughout and it
    /// goes away when the user closes it.
    ///
    /// Non-nil is what puts the sheet up, from wherever in the app the user happens to be.
    public private(set) var incoming: IncomingRequest?

    /// True while a request is in flight, so the screen can stop somebody pressing the button
    /// twice and starting two verifications of the same device.
    public private(set) var isWorking = false

    /// The user has answered, and the answer has gone. `isWorking` is not enough on its own and the
    /// difference is visible on screen: it is false again the instant *our* request returns, but the
    /// step does not move until the **other device** has answered too — the SDK calls `didFinish`
    /// when both ends agree, not when one of them does. So for the seconds in between, "They match"
    /// went back to looking like a button waiting to be pressed, on a screen whose question had
    /// already been answered. Pressing it again did nothing (the SDK guards it), which is arguably
    /// worse: the app looked broken rather than busy.
    public private(set) var hasAnswered = false

    /// Which end of this we are. See the note on the type: it decides who starts the comparison.
    private var isIncoming = false

    private let client: Client

    /// This account. A verification request from *another user* is a different feature with
    /// different words — "is this really Boris?" rather than "is this really my phone?" — and
    /// Iskra does not have it. Such a request is left alone rather than shown under a title that
    /// would be a lie about what the user is agreeing to.
    private let ownUserID: String

    private var controller: SessionVerificationController?

    init(client: Client, ownUserID: String) {
        self.client = client
        self.ownUserID = ownUserID
    }

    /// Starts listening for devices asking to be trusted. Called once, when the session starts.
    ///
    /// Failing is survivable and is not surfaced: an account that cannot reach its verification
    /// controller can still read its messages, and there is no screen up to put an error on.
    public func listen() async {
        guard controller == nil else { return }

        do {
            let controller = try await client.getSessionVerificationController()
            self.controller = controller

            controller.setDelegate(delegate: Updates { [weak self] event in
                Task { @MainActor [weak self] in
                    await self?.handle(event)
                }
            })
        } catch {
            Log.session.error("verification is not available: \(Log.describe(error), privacy: .public)")
        }
    }

    /// Asks this account's other devices to verify this one.
    public func start() async {
        guard !isWorking, step == .idle || step == .failed || step == .declined else { return }

        isWorking = true
        defer { isWorking = false }

        await listen()
        guard let controller else {
            step = .failed
            return
        }

        isIncoming = false

        do {
            step = .waitingForOtherDevice
            try await controller.requestDeviceVerification()
        } catch {
            Log.session.error("the verification would not start: \(Log.describe(error), privacy: .public)")
            step = .failed
        }
    }

    /// Yes, that device is mine.
    ///
    /// This does not yet grant anything — it agrees to *look*. The trust is granted several steps
    /// later, by `approve()`, after a person has compared seven pictures. Saying yes here is saying
    /// yes to a question about a name on a screen, and the protocol treats it as exactly that.
    public func accept() async {
        guard step == .asked, let request = incoming, !isWorking, !hasAnswered else { return }

        hasAnswered = true
        isWorking = true
        defer { isWorking = false }

        isIncoming = true

        do {
            // Two calls, and the first is not a formality: the SDK is watching no request in
            // particular until it is told which one, and accepting without acknowledging accepts
            // nothing.
            try await controller?.acknowledgeVerificationRequest(senderId: request.senderID,
                                                                 flowId: request.flowID)
            step = .negotiating
            try await controller?.acceptVerificationRequest()
        } catch {
            Log.session.error("the verification would not be accepted: \(Log.describe(error), privacy: .public)")
            step = .failed
        }
    }

    /// No, that device is not mine.
    ///
    /// The other side is told, rather than left waiting — and the user is told what it means, which
    /// is the part that matters: a device signing in to this account that the person holding the
    /// phone does not recognise is somebody else holding the password.
    public func refuse() async {
        guard step == .asked, let request = incoming, !isWorking, !hasAnswered else { return }

        hasAnswered = true
        isWorking = true
        defer { isWorking = false }

        // Acknowledged first for the same reason as `accept()`: there is nothing to cancel until
        // the SDK knows which request is being talked about.
        try? await controller?.acknowledgeVerificationRequest(senderId: request.senderID,
                                                              flowId: request.flowID)
        try? await controller?.cancelVerification()

        step = .refused
    }

    /// The pictures are the same on both screens. This is the answer that grants the trust, and it
    /// is the one moment in the app where a user's "yes" is a cryptographic claim — which is
    /// exactly why the screen asks them to *look*, and why there is a "they don't match" beside it
    /// rather than only a way to agree.
    public func approve() async {
        guard case .comparing = step, !hasAnswered else { return }

        hasAnswered = true
        isWorking = true
        defer { isWorking = false }

        do {
            try await controller?.approveVerification()
        } catch {
            Log.session.error("the verification would not complete: \(Log.describe(error), privacy: .public)")
            step = .failed
        }
    }

    /// They are not the same. Somebody is in the middle, or — far more likely — this was started
    /// twice and the user is looking at the wrong one. Either way the answer is no.
    public func decline() async {
        guard case .comparing = step, !hasAnswered else { return }

        hasAnswered = true
        isWorking = true
        defer { isWorking = false }

        try? await controller?.declineVerification()
        step = .declined
    }

    /// Closing the sheet, from wherever it was opened and at whatever point in the flow.
    ///
    /// A verification that is still live is cancelled — the other device is sitting on a screen
    /// waiting for an answer, and walking away without one leaves it there. A verification that has
    /// already ended is not: there is nothing to cancel, and asking the SDK to cancel a finished
    /// flow is asking it to undo a success.
    public func cancel() async {
        switch step {
        case .idle, .succeeded, .failed, .declined, .refused:
            break
        case .asked, .negotiating, .waitingForOtherDevice, .comparing:
            try? await controller?.cancelVerification()
        }

        reset()
    }

    /// Back to the beginning: the sheet is gone and nothing is in flight.
    public func reset() {
        step = .idle
        incoming = nil
        isIncoming = false
    }

    /// The session is ending. The delegate is unhooked here rather than in a `deinit`, for the same
    /// reason `RecoveryStore` does it: the controller is main-actor state and `deinit` is not on
    /// the actor.
    public func stop() {
        controller?.setDelegate(delegate: nil)
        controller = nil
        reset()
    }

    // MARK: - Private

    /// Whether a request that has just arrived should be put in front of the user.
    ///
    /// Pulled out of `handle` and made a function of its arguments so that it can be *tested*,
    /// which the rest of this type cannot be: reaching any other state needs a live `Client` and a
    /// second device on the account, and `swift test` has neither. Both of the refusals here are
    /// security decisions, and a security decision nobody can write a test for is a security
    /// decision that will be changed by accident one day.
    ///
    ///   - Another user's request is not one of this account's devices asking to be trusted. It is
    ///     a different feature — "is this really Boris?" — and Iskra does not have it. Showing it
    ///     under the words this sheet uses would be telling the user they were confirming their own
    ///     phone while they confirmed somebody else's identity.
    ///   - A second request arriving mid-answer would swap the device named on the screen for a
    ///     different one *underneath the buttons* — so "this is mine" would end up being about a
    ///     device whose name the user never read. Whoever is second waits.
    nonisolated static func shouldShow(_ request: IncomingRequest, to ownUserID: String, while step: Step) -> Bool {
        request.senderID == ownUserID && step == .idle
    }

    private func handle(_ event: Event) async {
        switch event {
        case let .requested(request):
            guard Self.shouldShow(request, to: ownUserID, while: step) else {
                Log.session.info("a verification request was left alone")
                return
            }

            incoming = request
            step = .asked

        case .accepted:
            // The request is ready, and both sides are told so. Exactly one of them starts the
            // comparison — the one that asked. See the note on the type.
            guard !isIncoming else { return }

            do {
                try await controller?.startSasVerification()
            } catch {
                Log.session.error("the comparison would not start: \(Log.describe(error), privacy: .public)")
                step = .failed
            }

        case .sasStarted:
            // Nothing to do but wait for the emoji, which arrive next.
            break

        case let .data(symbols):
            step = .comparing(symbols)

        case .failed:
            step = .failed

        case .cancelled:
            switch step {
            case .asked:
                // The other device gave up before the user answered. Nothing happened, and nothing
                // needs to be said about it — the sheet simply goes away.
                reset()
            case .declined, .refused, .succeeded:
                // The SDK sends a cancellation after a decline, and overwriting the answer the user
                // gave with it would lose the distinction the screen needs.
                break
            default:
                step = .declined
            }

        case .finished:
            step = .succeeded
        }
    }

    /// What the SDK tells us, flattened to something `Sendable` before it crosses to the main
    /// actor — the emoji become their symbols on the Rust thread, so no SDK object makes the hop.
    private enum Event: Sendable {
        case requested(IncomingRequest)
        case accepted
        case sasStarted
        case data([String])
        case failed
        case cancelled
        case finished
    }

    private final class Updates: SessionVerificationControllerDelegate {
        private let onEvent: @Sendable (Event) -> Void

        init(onEvent: @escaping @Sendable (Event) -> Void) {
            self.onEvent = onEvent
        }

        /// A device asking *us* to verify *it*.
        ///
        /// It is handed on and nothing more. It is emphatically not accepted here, and that is the
        /// whole point: agreeing to a verification request without a human looking at it would
        /// defeat the exercise entirely. The emoji exist precisely so that a person, not a program,
        /// decides that the device on the other end is theirs.
        func didReceiveVerificationRequest(details: SessionVerificationRequestDetails) {
            onEvent(.requested(IncomingRequest(flowID: details.flowId,
                                              senderID: details.senderProfile.userId,
                                              deviceID: details.deviceId,
                                              deviceName: details.deviceDisplayName)))
        }

        func didAcceptVerificationRequest() { onEvent(.accepted) }
        func didStartSasVerification() { onEvent(.sasStarted) }

        func didReceiveVerificationData(data: SessionVerificationData) {
            switch data {
            case let .emojis(emojis, _):
                // The symbols only. The SDK also hands over a name for each one — "Dog", "Cat" —
                // and they are English, from the specification, and they are not translated. Seven
                // English words under seven pictures in a Russian app would be the one place the
                // whole interface breaks its own voice, and they buy nothing: the comparison is
                // made with the eyes, against the same seven pictures on the other screen, and a
                // person matching a dog to a dog does not need to be told it is a dog.
                onEvent(.data(emojis.map { $0.symbol() }))

            case let .decimals(values):
                // The fallback the specification allows when the two sides cannot agree on emoji.
                // Rare, and it costs one line to not be a blank screen when it happens.
                onEvent(.data(values.map(String.init)))
            }
        }

        func didFail() { onEvent(.failed) }
        func didCancel() { onEvent(.cancelled) }
        func didFinish() { onEvent(.finished) }
    }
}
