import Foundation
import Observation
import MatrixRustSDK

/// Proving that this device is really yours, by comparing pictures with a device that already is.
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
/// Nothing here is cryptography written in Swift, and nothing here may become that. The emoji are
/// the SDK's, the comparison is the SDK's, and this type is a state machine and a list of pictures.
@MainActor
@Observable
public final class VerificationStore {
    public enum Step: Sendable, Equatable {
        /// Nothing started.
        case idle
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
    }

    public private(set) var step: Step = .idle

    /// True while a request is in flight, so the screen can stop somebody pressing the button
    /// twice and starting two verifications of the same device.
    public private(set) var isWorking = false

    private let client: Client
    private var controller: SessionVerificationController?

    init(client: Client) {
        self.client = client
    }

    /// Asks this account's other devices to verify this one.
    public func start() async {
        guard !isWorking, step != .waitingForOtherDevice else { return }

        isWorking = true
        defer { isWorking = false }

        do {
            let controller = try await client.getSessionVerificationController()
            self.controller = controller

            controller.setDelegate(delegate: Updates { [weak self] event in
                Task { @MainActor [weak self] in
                    await self?.handle(event)
                }
            })

            step = .waitingForOtherDevice
            try await controller.requestDeviceVerification()
        } catch {
            Log.session.error("the verification would not start: \(String(describing: error), privacy: .public)")
            step = .failed
        }
    }

    /// The pictures are the same on both screens. This is the answer that grants the trust, and it
    /// is the one moment in the app where a user's "yes" is a cryptographic claim — which is
    /// exactly why the screen asks them to *look*, and why there is a "they don't match" beside it
    /// rather than only a way to agree.
    public func approve() async {
        guard case .comparing = step else { return }

        isWorking = true
        defer { isWorking = false }

        do {
            try await controller?.approveVerification()
        } catch {
            Log.session.error("the verification would not complete: \(String(describing: error), privacy: .public)")
            step = .failed
        }
    }

    /// They are not the same. Somebody is in the middle, or — far more likely — this was started
    /// twice and the user is looking at the wrong one. Either way the answer is no.
    public func decline() async {
        guard case .comparing = step else { return }

        isWorking = true
        defer { isWorking = false }

        try? await controller?.declineVerification()
        step = .declined
    }

    /// Backed out before the pictures appeared.
    public func cancel() async {
        try? await controller?.cancelVerification()
        step = .idle
    }

    /// Closing the screen. The delegate is unhooked here rather than in a `deinit`, for the same
    /// reason `RecoveryStore` does it: the controller is main-actor state and `deinit` is not on
    /// the actor.
    public func stop() {
        controller?.setDelegate(delegate: nil)
        controller = nil
    }

    /// Back to the beginning, after a failure the user wants to try again from.
    public func reset() {
        step = .idle
    }

    // MARK: - Private

    private func handle(_ event: Event) async {
        switch event {
        case .accepted:
            // Somebody said yes on the other device. Turn the request into the flow that actually
            // produces the pictures — the SDK does not do this on its own, and a verification that
            // stops here is one where both screens sit waiting for the other.
            do {
                try await controller?.startSasVerification()
            } catch {
                Log.session.error("the comparison would not start: \(String(describing: error), privacy: .public)")
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
            // Only if we are not already finished: the SDK sends a cancellation after a decline,
            // and overwriting `.declined` with it would lose the distinction the screen needs.
            if step != .declined, step != .succeeded { step = .declined }

        case .finished:
            step = .succeeded
        }
    }

    /// What the SDK tells us, flattened to something `Sendable` before it crosses to the main
    /// actor — the emoji become their symbols on the Rust thread, so no SDK object makes the hop.
    private enum Event: Sendable {
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

        /// Somebody else's device asking *us* to verify *it*.
        ///
        /// Deliberately not acted on, and the limitation is worth stating rather than leaving to be
        /// discovered: Iskra can ask to be verified, and cannot yet answer somebody who asks. So a
        /// new Iskra device is verified from Element, or from the web client, or with the recovery
        /// key — and two Iskra devices cannot yet verify each other.
        ///
        /// It is a no-op rather than an automatic yes, and that is the whole point. Accepting a
        /// verification request without a human looking at it would defeat the exercise entirely:
        /// the emoji exist precisely so that a person, not a program, decides that the device on
        /// the other end is theirs. An interface that quietly agreed would be worse than one that
        /// cannot answer at all.
        func didReceiveVerificationRequest(details: SessionVerificationRequestDetails) {}

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
