import Foundation
import Observation
import IskraCore

/// A call somebody answered, waiting for a screen to be opened on it.
public struct AnsweredCall: Sendable, Equatable, Identifiable {
    public let roomID: String
    public let isVideo: Bool
    public var id: String { roomID }
}

/// Everything about a call arriving at this device.
///
/// ## Why it is a singleton, and why it must not need a window
///
/// A VoIP push is a **background launch**. iOS may start this process with no scene connected, no
/// `WindowGroup` built and no view ever drawn, hand over the push, and expect a ringing call to be
/// reported before the callback returns. Anything about ringing that waits for a view to exist is
/// a call that silently never rings — so the provider, the ledger and the resolver all hang off
/// `shared`, and the *screen* observes this rather than the other way round.
///
/// ## The rule that governs the whole file
///
/// Since iOS 13, every delivered VoIP push must end in `CXProvider.reportNewIncomingCall`. Not
/// usually, not when it turns out to be a real call — every one. Miss it and iOS starts holding
/// pushes back and then stops delivering them to this app at all, until it is reinstalled, with
/// nothing written anywhere to say why.
///
/// So `ring(payload:completion:)` reports **first**, synchronously, with a placeholder name, and
/// only then goes and finds out who is calling. Every path after that either fills the name in or
/// ends the call with a reason. There is no path that decides not to report.
///
/// ## macOS
///
/// There is no CallKit on macOS and no VoIP push either — the Mac app has no `aps-environment` at
/// all. A Mac learns about a call the way it learns about everything else, from sync: the chat
/// list says "Идёт звонок" and the room carries the strip to join it. It does not ring, and this
/// type does nothing there beyond holding the answered call for the screen.
@MainActor
@Observable
public final class IncomingCallCenter {
    public static let shared = IncomingCallCenter()

    /// Set when somebody answers. The root view watches it and opens the call screen.
    public private(set) var answered: AnsweredCall?

    /// The signed-in session, when there is one. Nil during a background launch before restore,
    /// which is exactly why `RingResolver` can also stand up a client of its own.
    private var session: UserSession?

    #if os(iOS)
    /// Built on first use rather than in `init`, because it needs `self` — and ignored by
    /// observation, because nothing on screen watches the provider; screens watch `answered`.
    @ObservationIgnored
    private lazy var callKit = CallKitService(center: self)
    #endif

    /// The rings currently on screen, by their CallKit UUID. Kept so that answering can find the
    /// room, and so that a decline knows which event to decline.
    private var ringing: [UUID: CallRing] = [:]

    private init() {}

    // MARK: - The session

    public func signedIn(_ session: UserSession) {
        self.session = session
    }

    public func signedOut() {
        session = nil
        for uuid in ringing.keys {
            end(uuid, because: .alreadyOver)
        }
        ringing = [:]
    }

    /// The screen has opened the answered call and it need not be answered again.
    public func consumeAnswered() {
        answered = nil
    }

    // MARK: - A push arrives

    #if os(iOS)
    /// A VoIP push. **Reports to CallKit before it returns**, then resolves who is calling.
    ///
    /// `completion` is PushKit's, and it is called from inside the report's own completion handler
    /// rather than at the end of this method: telling PushKit we are done before CallKit has taken
    /// the call is the shape that gets the process killed.
    public func ring(payload: [AnyHashable: Any], completion: @escaping @Sendable () -> Void) {
        let roomID = payload["room_id"] as? String
        let eventID = payload["event_id"] as? String

        // Derived from the event, never random — see `RingID`. A retried push must land on the
        // call that is already ringing rather than starting a second one from the same person.
        // With no event id there is nothing to derive from and nothing to resolve either; it is
        // still reported, and then ended immediately.
        let uuid = eventID.map(RingID.uuid(forEventID:)) ?? UUID()

        callKit.reportIncoming(uuid: uuid,
                               title: String(app: Strings.Call.incoming),
                               handle: roomID ?? "",
                               isVideo: false) { @MainActor [weak self] in
            completion()

            guard let self, let roomID, let eventID else {
                self?.end(uuid, because: .notACall)
                return
            }

            RingLedger.reported(eventID: eventID)
            Task { await self.identify(uuid: uuid, roomID: roomID, eventID: eventID) }
        }
    }
    #endif

    /// Finds out who is calling and either fills the name in or ends the call.
    private func identify(uuid: UUID, roomID: String, eventID: String) async {
        let outcome: RingOutcome
        if let session {
            outcome = await session.resolveRing(roomID: roomID, eventID: eventID)
        } else {
            // A cold background launch: nobody has restored a session yet, so the resolver stands
            // one up the way the notification extension does.
            outcome = await RingResolver().resolve(roomID: roomID, eventID: eventID)
        }

        switch outcome {
        case let .ring(ring):
            ringing[uuid] = ring
            #if os(iOS)
            callKit.update(uuid: uuid, title: ring.displayTitle, isVideo: ring.isVideo)
            #endif
            // A ring that nobody answers has to stop by itself. The caller's own expiry is
            // believed only up to a point — see `CallRing.ringingTime`.
            scheduleGiveUp(uuid: uuid, after: ring.ringingTime())

            // And stop as soon as the other side says it is over, which is usually long before
            // the timer: somebody hangs up, or answers on another device.
            await watchForDecline(uuid: uuid, ring: ring)

        case let .over(reason, _):
            end(uuid, because: reason)

        case .notSignedIn:
            Log.calls.error("a call rang on a device where nobody is signed in")
            end(uuid, because: .alreadyOver)

        case let .failed(reason):
            Log.calls.error("the ring could not be identified: \(reason, privacy: .public)")
            end(uuid, because: .alreadyOver)
        }
    }

    private func scheduleGiveUp(uuid: UUID, after seconds: TimeInterval) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, ringing[uuid] != nil else { return }
            end(uuid, because: .expired)
        }
    }

    /// Subscribes to the other side hanging up or answering elsewhere, for as long as it rings.
    private func watchForDecline(uuid: UUID, ring: CallRing) async {
        guard let session else { return }
        await session.watchCallDeclines(ring: ring) { [weak self] in
            Task { @MainActor [weak self] in
                self?.end(uuid, because: .declinedElsewhere)
            }
        }
    }

    // MARK: - Answering and ending

    /// CallKit says the person answered.
    func answerRing(_ uuid: UUID) {
        guard let ring = ringing[uuid] else { return }
        answered = AnsweredCall(roomID: ring.roomID, isVideo: ring.isVideo)
        RingLedger.ended(eventID: ring.eventID)
    }

    /// CallKit says the person hung up — which, before answering, means they declined.
    func declineRing(_ uuid: UUID) {
        guard let ring = ringing.removeValue(forKey: uuid) else { return }
        RingLedger.ended(eventID: ring.eventID)

        guard let session else { return }
        // Fire and forget: CallKit gives an action about five seconds before it tears the call
        // down anyway, and telling the caller is worth doing even if it lands after that.
        Task { await session.declineCall(ring: ring) }
    }

    /// Ends a call we reported and then found nothing behind.
    private func end(_ uuid: UUID, because reason: RingEnded) {
        if let ring = ringing.removeValue(forKey: uuid) {
            RingLedger.ended(eventID: ring.eventID)
        }
        #if os(iOS)
        callKit.end(uuid: uuid, because: reason)
        #endif
    }
}
