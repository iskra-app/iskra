import Foundation
import MatrixRustSDK

/// Calls, hung off the session.
///
/// An extension in its own file, like `RoomCreation`, and for the same reason: it needs the
/// `Client`, which is `internal` precisely so that siblings like this one can reach it without the
/// SDK leaving `IskraCore`.
public extension UserSession {
    /// Settles whether this account can call at all. Called once from `start()`.
    ///
    /// Two questions, and both have to say yes. The homeserver is asked whether it knows a LiveKit
    /// focus — that is where the audio would go — and `.well-known` is asked which Element Call
    /// deployment it points its users at, because that is what draws the call.
    ///
    /// Nothing here throws and nothing is shown if it fails. A server that does not do calls is
    /// the normal case, not an error, and the way the app says so is that there is no call button.
    func loadCallAvailability(discovery: ElementCallDiscovery = ElementCallDiscovery()) async {
        let carries = (try? await client.isLivekitRtcSupported()) ?? false

        // Something typed by hand wins, and it is the only thing that may: see
        // `BetaFeatures.elementCallURL`. It is not a fallback for a server that stayed silent —
        // it is somebody naming a deployment on purpose.
        let widget: URL?
        if let typed = BetaFeatures.elementCallURL() {
            widget = typed
        } else {
            widget = await discovery.widgetURL(forServerName: serverName)
        }

        let availability = CallAvailability(widgetURL: widget, serverCarriesCalls: carries)
        callAvailability = availability

        Log.calls.info("""
            calls available: \(availability.isAvailable, privacy: .public) \
            (server carries them: \(carries, privacy: .public), \
            an address was found: \(widget != nil, privacy: .public))
            """)
    }

    /// The homeserver's *name*, which is the host that serves `.well-known`.
    ///
    /// `Client.server()` is the right answer and it is optional; the server part of the user's own
    /// Matrix ID is the fallback, and it is the same string in every case that matters — an
    /// account on `matrix.org` has `@someone:matrix.org` whatever the API's base URL turns out to
    /// be. Deliberately **not** `client.homeserver()`, which is the delegated API host and, when
    /// the bridge is on, a loopback address.
    var serverName: String {
        if let named = client.server(), !named.isEmpty { return named }
        return (try? client.userIdServerName()) ?? ""
    }

    /// A call in one room, built when its screen opens.
    ///
    /// Nil where calls are not available at all, so the screen cannot be reached by accident — the
    /// button is already hidden in that case, and this is the second lock on the same door.
    func call(forRoomID roomID: String) -> CallStore? {
        if let open = openCalls[roomID]?.value { return open }

        guard let widgetBase = callAvailability.widgetURL,
              callAvailability.serverCarriesCalls,
              let deviceID,
              let room = roomList.room(withID: roomID) ?? (try? client.getRoom(roomId: roomID))
        else {
            return nil
        }

        let store = CallStore(room: room,
                              ownUserID: userID,
                              deviceID: deviceID,
                              widgetBase: widgetBase)

        // Empty boxes are swept on the way past, exactly as `timeline(forRoomID:)` does it.
        openCalls = openCalls.filter { $0.value.value != nil }
        openCalls[roomID] = UserSession.WeakBox(value: store)

        return store
    }

    /// Looks up an incoming ring with this session's own client.
    ///
    /// The live-session half of `RingResolver`. Restoring a second client from a process that
    /// already has one would open the same encrypted store twice for no reason.
    func resolveRing(roomID: String, eventID: String) async -> RingOutcome {
        do {
            return try await withTimeout(RingResolver.budget) { [client] in
                try await RingResolver.resolve(roomID: roomID, eventID: eventID, client: client)
            }
        } catch is TimeoutError {
            Log.calls.error("the ring did not resolve inside \(RingResolver.budget)")
            return .failed("timed out")
        } catch {
            Log.calls.error("the ring would not resolve: \(Log.describe(error), privacy: .public)")
            return .failed(Log.describe(error))
        }
    }

    /// Tells the caller this device is not taking the call.
    ///
    /// `declineCall` is what stops the *other* devices ringing too — it is a message to the room,
    /// not a local dismissal. Hence a real request rather than simply tearing the screen down.
    func declineCall(ring: CallRing) async {
        guard let room = roomList.room(withID: ring.roomID) ?? (try? client.getRoom(roomId: ring.roomID)) else {
            return
        }
        do {
            try await room.declineCall(rtcNotificationEventId: ring.eventID)
        } catch {
            Log.calls.error("the decline would not send: \(Log.describe(error), privacy: .public)")
        }
        stopWatchingDeclines(for: ring)
    }

    /// Watches for somebody else turning this ring down — another of the user's own devices
    /// answering or declining — so that this one stops ringing too.
    ///
    /// The handle is kept by the session, because letting go of it unsubscribes and the thing
    /// being waited for arrives while nobody is holding anything.
    func watchCallDeclines(ring: CallRing, onDecline: @escaping @Sendable () -> Void) async {
        guard let room = roomList.room(withID: ring.roomID) ?? (try? client.getRoom(roomId: ring.roomID)),
              callDeclineHandles[ring.eventID] == nil
        else {
            return
        }

        do {
            callDeclineHandles[ring.eventID] = try room.subscribeToCallDeclineEvents(
                rtcNotificationEventId: ring.eventID,
                listener: CallDeclines(onDecline: onDecline)
            )
        } catch {
            Log.calls.error("could not watch for declines: \(Log.describe(error), privacy: .public)")
        }
    }

    /// Unsubscribes once the ring is over, whichever way it ended.
    func stopWatchingDeclines(for ring: CallRing) {
        callDeclineHandles.removeValue(forKey: ring.eventID)?.cancel()
    }

    /// Whether this room, rather than this account, will let the user start a call.
    ///
    /// Asked of the room's power levels and not guessed from a badge: joining a call means writing
    /// an `m.call.member` state event, so the question of whether somebody may call is exactly the
    /// question of whether they may write one.
    func canStartCall(inRoomID roomID: String) async -> Bool {
        guard callAvailability.isAvailable,
              let room = roomList.room(withID: roomID) ?? (try? client.getRoom(roomId: roomID))
        else {
            return false
        }
        guard let levels = try? await room.getPowerLevels() else { return false }
        return (try? levels.canUserSendState(userId: userID, stateEvent: .callMember)) ?? false
    }
}

/// Somebody turned the ring down — on another of this user's devices, or on the caller's side.
///
/// The same shape as `RoomInfoUpdates`: a tiny class because the SDK's listener protocols are
/// class-bound, in a file of its own reason rather than nested, because two different stores could
/// want it.
final class CallDeclines: CallDeclineListener {
    private let onDecline: @Sendable () -> Void

    init(onDecline: @escaping @Sendable () -> Void) {
        self.onDecline = onDecline
    }

    /// The decliner's ID is dropped. Which of your own devices refused a call is not a fact the
    /// phone in your hand has anything to say about — it simply stops ringing.
    func call(declinerUserId: String) {
        onDecline()
    }
}
