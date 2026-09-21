import Foundation
import MatrixRustSDK

/// Turns the two identifiers in a VoIP push into a call worth ringing, or into the reason it is not.
///
/// The sibling of `PushDecoder`, and the same job in a harder place: a push carries a room ID and
/// an event ID, and everything a person needs in order to decide whether to answer — who is
/// calling, what kind of call, whether it is still ringing — is inside an encrypted event that has
/// to be fetched and decrypted first.
///
/// **What it is not is a gate.** Nothing here decides whether to report the call to CallKit; that
/// has already happened by the time this runs, and it had to. See `IncomingCallCenter`. Every
/// outcome below, including the failures, is something the caller turns into either a name on a
/// ringing call or a reason to end one.
///
/// ## Two clients, and it matters which
///
/// When the app is already running and signed in, the session's own `Client` is used — restoring a
/// second one would open the same encrypted store from the same process for no reason. When the
/// push woke a cold app, there is no session yet and one is restored here, exactly as the
/// notification extension does it.
public actor RingResolver {
    private let environment: AppEnvironment

    public init(environment: AppEnvironment = .default) {
        self.environment = environment
    }

    /// How long this is allowed to take.
    ///
    /// Shorter than `PushDecoder`'s twenty seconds, and for a reason that is the opposite of that
    /// one: nobody is waiting for a notification to appear, but somebody *is* looking at a ringing
    /// call with a placeholder name on it. Ten seconds of "Iskra" instead of "Аня" is the most
    /// this should ever cost, and a ring that takes longer than that to identify is one the caller
    /// has probably already given up on.
    static let budget: Duration = .seconds(10)

    /// Looks the ring up with a client of its own. For a push that woke the app from cold.
    public func resolve(roomID: String, eventID: String) async -> RingOutcome {
        do {
            return try await withTimeout(Self.budget) {
                guard let client = try await AuthenticationService(environment: self.environment)
                    .restoreClient() else {
                    return RingOutcome.notSignedIn
                }
                return try await Self.resolve(roomID: roomID, eventID: eventID, client: client)
            }
        } catch is TimeoutError {
            Log.calls.error("the ring did not resolve inside \(Self.budget)")
            return .failed("timed out after \(Self.budget)")
        } catch {
            Log.calls.error("the ring would not resolve: \(Log.describe(error), privacy: .public)")
            return .failed(Log.describe(error))
        }
    }

    /// The same work against a client somebody already has.
    static func resolve(roomID: String, eventID: String, client: Client) async throws -> RingOutcome {
        // `.multipleProcesses` for the same reason `PushDecoder` uses it: the notification
        // extension may be holding the same SQLite file at this exact moment, since the ordinary
        // copy of this push is being decrypted over there while this runs over here.
        let notifications = try await client.notificationClient(processSetup: .multipleProcesses)
        let status = try await notifications.getNotification(roomId: roomID, eventId: eventID)

        guard case let .event(item) = status else {
            return .over(.notACall, nil)
        }

        guard case let .timeline(event) = item.event,
              let content = try? event.content(),
              case let .messageLike(messageLike) = content,
              case let .rtcNotification(notificationType, expirationTs, callIntent) = messageLike
        else {
            // Not an `m.rtc.notification` at all. This is the gateway having sent an ordinary
            // message down the VoIP pusher, which means the push rule or the Sygnal filter is
            // wrong — worth a line in the log, because the symptom on the device is a call from
            // somebody who did not call.
            Log.calls.error("a VoIP push carried something that is not a call")
            return .over(.notACall, nil)
        }

        // `.notification` is the quiet kind: a call was started, do not ring. It is a legitimate
        // thing for a sender to ask for and it has no business waking anybody up.
        guard notificationType == .ring else {
            return .over(.notACall, nil)
        }

        let senderName = item.senderInfo.displayName ?? event.senderId()
        let roomName = item.roomInfo.displayName.isEmpty
            ? String(core: CoreStrings.Room.untitled)
            : item.roomInfo.displayName

        let ring = CallRing(roomID: roomID,
                            eventID: eventID,
                            // The name this device calls them, if it has been given one — the same
                            // rule the lock screen already follows for messages. A person renamed
                            // in `LocalNames` who then rings should not arrive under the name they
                            // were renamed away from.
                            callerName: LocalNames.name(for: roomID) ?? senderName,
                            callerID: event.senderId(),
                            roomName: roomName,
                            isDirect: item.roomInfo.isDm,
                            isVideo: callIntent == .video,
                            // Zero is not a date in 1970, it is a sender who said nothing. Read
                            // literally it would make every such ring already expired — which is
                            // the kind of bug that shows up as "calls from that one client never
                            // ring" and is looked for everywhere except here.
                            expiresAt: expirationTs == 0 ? nil : MessagePreview.date(from: expirationTs))

        if ring.hasExpired() {
            return .over(.expired, ring)
        }

        // Whether this is still worth answering, asked of the room rather than of the push. A ring
        // that was answered on an iPad ten seconds ago is a ring the phone must not make.
        if let room = try? client.getRoom(roomId: roomID) {
            let participants = room.activeRoomCallParticipants()
            let ownID = (try? client.userId()) ?? ""

            if participants.contains(ownID) {
                return .over(.answeredElsewhere, ring)
            }
            // The call had people in it and has none now. Not the same as "never started": a ring
            // arrives before anybody has joined, so an empty list on its own means nothing.
            if !room.hasActiveRoomCall(), !participants.isEmpty {
                return .over(.alreadyOver, ring)
            }
        }

        return .ring(ring)
    }
}
