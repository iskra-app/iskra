import Foundation
import MatrixRustSDK

/// Turns the two identifiers in a push into the sentence a person reads.
///
/// This is the whole of stage 7 that does not depend on a push gateway, and it is also
/// the whole of stage 7 that can go wrong in an interesting way. A gateway is plumbing:
/// it delivers a room ID and an event ID and has no idea what they mean. *This* is the
/// part that has to open an encrypted SQLite store belonging to another process, find an
/// event by ID, decrypt it with Megolm keys the app put there, and do all of it in the
/// thirty seconds iOS gives a notification extension before it kills it and shows the
/// fallback text instead.
///
/// Which is why it can be driven without a gateway at all, and is: `Iskra
/// --probe-notification <roomID> <eventID>` runs exactly this, in the signed app, against
/// a real event. See `Apps/Shared/NotificationProbe.swift`.
public actor PushDecoder {
    private let environment: AppEnvironment

    public init(environment: AppEnvironment = .default) {
        self.environment = environment
    }

    /// Everything a Matrix push actually contains, made into something to read.
    ///
    /// Never throws. A notification extension has exactly one obligation — call its
    /// content handler, once — and an error thrown up out of here would be an error
    /// somebody has to remember to catch on the one path where forgetting means the user
    /// gets no notification at all. So every way this can fail is a `PushOutcome` instead,
    /// and the caller has to look at it to find out what happened.
    public func notification(roomID: String, eventID: String) async -> PushOutcome {
        let client: Client
        do {
            guard let restored = try await AuthenticationService(environment: environment)
                .restorePreviousSession() else {
                return .notSignedIn
            }
            client = restored
        } catch {
            // The overwhelmingly likely cause is `StorageError.appGroupUnavailable` — the
            // extension has a different bundle ID from the app, so it needs the App Group
            // and the Keychain group granted to it *separately*, and a profile that forgot
            // one of them fails here and nowhere else.
            Log.push.error("the session would not open in this process: \(error)")
            return .failed(String(describing: error))
        }

        do {
            // `.multipleProcesses` is the reason the store lives in an App Group at all. It
            // tells the SDK that the app may be awake and holding the same SQLite file right
            // now, so the two take a cross-process lock instead of writing over each other.
            // `.singleProcess` here would be a database corrupted by a push that arrived
            // while the user happened to have the app open — rare, silent, and fatal.
            let notifications = try await client.notificationClient(processSetup: .multipleProcesses)

            let status = try await withTimeout(Self.budget) {
                try await notifications.getNotification(roomId: roomID, eventId: eventID)
            }
            return PushMapper.outcome(for: status, roomID: roomID, eventID: eventID)
        } catch is TimeoutError {
            // Bounded for a harder reason than the rest of the app. Everywhere else a stalled
            // call means a spinner; here it means iOS runs out of patience, kills the process
            // mid-decrypt, and shows the fallback push — so we give up first, with time left
            // to put something honest on the screen ourselves.
            Log.push.error("the event did not arrive inside \(Self.budget)")
            return .failed("timed out after \(Self.budget)")
        } catch {
            Log.push.error("the event would not decrypt: \(error)")
            return .failed(String(describing: error))
        }
    }

    /// A real room and a real message to try this on, for `Iskra --probe-notification` when it
    /// is given nothing to work with. Nil if nobody is signed in, or if there is not a single
    /// message anywhere in the account.
    ///
    /// Public because the probe lives in the app shell and the app shell may not hold a
    /// `Client`; a diagnostic, and marked as one — nothing in the app calls this. See
    /// `RecentMessage` for why it has to exist at all.
    public func recentMessage() async -> (roomID: String, eventID: String)? {
        guard let client = try? await AuthenticationService(environment: environment)
            .restorePreviousSession() else {
            return nil
        }
        return await RecentMessage.mostRecent(client: client)
    }

    // MARK: - Private

    /// Ten seconds short of the thirty iOS allows, which is not a guess: whatever is left when
    /// this expires is the time we have to write a fallback and call the content handler, and
    /// a handler that is never called shows nothing at all.
    private static let budget: Duration = .seconds(20)
}
