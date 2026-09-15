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
        // The whole thing is bounded, not just the last step of it.
        //
        // The budget used to start counting at `getNotification` — which is to say, *after*
        // restoring the session and building a notification client, both of which reach the network
        // and neither of which was bounded at all. So the twenty seconds promised out of the thirty
        // iOS allows were twenty seconds of whatever was left, and if what was left was nothing, the
        // process was killed mid-decrypt with no fallback written and the user got the server's
        // "New message" — the exact outcome the budget exists to prevent.
        do {
            return try await withTimeout(Self.budget) {
                try await self.decrypt(roomID: roomID, eventID: eventID)
            }
        } catch is TimeoutError {
            // Bounded for a harder reason than the rest of the app. Everywhere else a stalled call
            // means a spinner; here it means iOS runs out of patience, kills the process
            // mid-decrypt, and shows the fallback push — so we give up first, with time left to put
            // something honest on the screen ourselves.
            Log.push.error("the push did not decrypt inside \(Self.budget)")
            return .failed("timed out after \(Self.budget)")
        } catch {
            Log.push.error("the push would not decrypt: \(Log.describe(error), privacy: .public)")
            return .failed(Log.describe(error))
        }
    }

    /// The work itself, so that one deadline can be drawn around all of it.
    private func decrypt(roomID: String, eventID: String) async throws -> PushOutcome {
        let client: Client
        do {
            guard let restored = try await AuthenticationService(environment: environment)
                .restoreClient() else {
                return .notSignedIn
            }
            client = restored
        } catch {
            // The overwhelmingly likely cause is `StorageError.appGroupUnavailable` — the
            // extension has a different bundle ID from the app, so it needs the App Group
            // and the Keychain group granted to it *separately*, and a profile that forgot
            // one of them fails here and nowhere else.
            Log.push.error("the session would not open in this process: \(Log.describe(error), privacy: .public)")
            return .failed(Log.describe(error))
        }

        // `.multipleProcesses` is the reason the store lives in an App Group at all. It tells the
        // SDK that the app may be awake and holding the same SQLite file right now, so the two take
        // a cross-process lock instead of writing over each other. `.singleProcess` here would be a
        // database corrupted by a push that arrived while the user happened to have the app open —
        // rare, silent, and fatal.
        let notifications = try await client.notificationClient(processSetup: .multipleProcesses)
        let status = try await notifications.getNotification(roomId: roomID, eventId: eventID)

        let outcome = PushMapper.outcome(for: status, roomID: roomID, eventID: eventID)

        // If the app lock is on and the app is locked, the message decrypts but its words never reach
        // the screen: the extension reads the same lock facts the app wrote to the shared defaults
        // and strips the notification down to "New message". The decryption still happened — tapping
        // the banner opens the right room, once the user is past the lock.
        let locked = AppLock.isLockedNow(defaults: UserDefaults(suiteName: AppEnvironment.appGroupIdentifier))
        let redacted = PushMapper.redactIfLocked(outcome, locked: locked)

        // The picture goes on last, and only onto something that is still going to be shown. A
        // locked phone has had its words taken away by the line above; adding the sender's face
        // back underneath them would give away exactly what was just withheld.
        guard case let .show(notification) = redacted, !locked else { return redacted }
        return .show(notification.withAvatar(await avatar(for: notification, client: client)))
    }

    /// The sender's avatar, or nil.
    ///
    /// Bounded twice over, and both bounds are the point. `avatarBudget` is short because this is
    /// the one part of a notification nobody is waiting for: a face is worth two seconds and not a
    /// second more, and the alternative to a slow avatar is not a slow notification but *no*
    /// notification, when iOS runs out of patience with the extension and shows the server's
    /// fallback text instead. And the bytes are capped, because this runs in a process with 24 MB
    /// to its name and the URL points at a server that can say anything it likes.
    ///
    /// Every failure here returns nil and says so quietly. There is no error worth showing: a
    /// notification without a picture is a notification.
    private func avatar(for notification: PushNotification, client: Client) async -> Data? {
        guard let url = notification.avatarURL, !url.isEmpty else { return nil }

        do {
            let data = try await withTimeout(Self.avatarBudget) {
                let source = try MediaSource.fromUrl(url: url)
                return try await client.getMediaContent(mediaSource: source)
            }

            guard data.count <= Self.avatarLimit else {
                Log.push.error("the sender's avatar was too large to put on a notification")
                return nil
            }

            return data
        } catch {
            Log.push.error("the sender's avatar could not be fetched: \(Log.describe(error), privacy: .public)")
            return nil
        }
    }

    /// Two seconds, out of the twenty the whole decryption gets. Deliberately a small share: the
    /// words are the notification and the picture is decoration, and decoration does not get to
    /// spend the budget that the words need.
    private static let avatarBudget: Duration = .seconds(2)

    /// 2 MB. An avatar is a small square and nothing sane is larger; the number is here because
    /// the extension has 24 MB in total, and "whatever the server sends" is not a size.
    private static let avatarLimit = 2 * 1024 * 1024

    /// A real room and a real message to try this on, for `Iskra --probe-notification` when it
    /// is given nothing to work with. Nil if nobody is signed in, or if there is not a single
    /// message anywhere in the account.
    ///
    /// Public because the probe lives in the app shell and the app shell may not hold a
    /// `Client`; a diagnostic, and marked as one — nothing in the app calls this. See
    /// `RecentMessage` for why it has to exist at all.
    public func recentMessage() async -> (roomID: String, eventID: String)? {
        guard let client = try? await AuthenticationService(environment: environment)
            .restoreClient() else {
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
