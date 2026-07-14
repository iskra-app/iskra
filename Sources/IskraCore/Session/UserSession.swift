import Foundation
import Observation
import MatrixRustSDK

/// The signed-in user, and everything hanging off them.
///
/// This is what the app holds once sign-in succeeds. It owns the `Client` so that
/// nothing above `IskraCore` ever touches the SDK directly.
@MainActor
@Observable
public final class UserSession {
    public let userID: String
    public let roomList: RoomListStore
    public let search: SearchStore

    /// What the user calls themselves, for the toolbar avatar and the settings screen.
    ///
    /// Starts as the local part of the Matrix ID — "@boris:matrix.org" reads as
    /// "boris" — because that is knowable without asking the server, and a screen that
    /// shows a name immediately is better than one that shows a blank while a request
    /// is in flight. `start()` then replaces it with the real display name if there is
    /// one.
    public private(set) var displayName: String
    public private(set) var avatarURL: String?

    /// The name of *this* device, as the rest of the account sees it — and the only true
    /// thing the encryption screen can say about sessions, since the others cannot be
    /// reached at all (see `ROADMAP.md`, stage 6).
    ///
    /// Resolved once, here, exactly like `userID`: it is fixed for the life of the client,
    /// and asking the SDK again on every read would cross the FFI boundary to be told the
    /// same thing. Optional rather than `?? ""`, because a device with no ID is a thing the
    /// screen should decline to talk about rather than a blank line under a heading.
    public let deviceID: String?

    /// Internal rather than private, because `RoomCreation` is an extension in another
    /// file and needs it. The rule it is kept under is unchanged: the `Client` does not
    /// leave `IskraCore`, and nothing above this layer holds one.
    let client: Client
    private let authentication: AuthenticationService

    public init(client: Client, authentication: AuthenticationService) {
        self.client = client
        self.authentication = authentication
        let userID = (try? client.userId()) ?? ""
        self.userID = userID
        self.deviceID = try? client.deviceId()
        self.displayName = Self.localPart(of: userID)
        self.roomList = RoomListStore(client: client)
        self.search = SearchStore(client: client)
    }

    /// The server has stopped accepting this session, and nobody on this device asked it to.
    ///
    /// Somebody ended the session from another client, or an administrator deactivated the
    /// account. Until this existed the app simply *did not find out*: sync began failing, the room
    /// list froze on whatever was in the cache, messages went into the send queue and stayed
    /// there, and every screen went on looking exactly as it had. The only symptom was an app that
    /// had quietly stopped being connected to anything, and the only cure was to guess as much and
    /// sign out by hand.
    ///
    /// Read by `IskraRootView`, which takes the app back to the sign-in screen and says why.
    public private(set) var wasEndedElsewhere = false

    /// Kept alive because dropping it unsubscribes. Cancelled in `signOut()`.
    private var authErrorHandle: TaskHandle?

    /// Starts the sync loop. Everything else follows from this.
    public func start() async throws {
        // Before the sync loop, not after: the token can be refused by the very first request the
        // loop makes, and a delegate registered afterwards would miss it.
        authErrorHandle = try? client.setDelegate(delegate: AuthErrors { [weak self] in
            Task { @MainActor [weak self] in
                await self?.endedElsewhere()
            }
        })

        await loadProfile()
        try await roomList.start()
    }

    /// Tears the session down locally, without asking the server for permission it has already
    /// withdrawn. See `wasEndedElsewhere`.
    private func endedElsewhere() async {
        guard !wasEndedElsewhere else { return }
        wasEndedElsewhere = true

        Log.session.error("the server no longer accepts this session; signing out locally")

        await roomList.stop()

        authErrorHandle?.cancel()
        authErrorHandle = nil

        // Not `signOut()`: that one asks the server to forget the device, and the server has
        // already forgotten it. The local half — keys, tokens, the encrypted store — happens
        // exactly as it would have.
        await authentication.forgetSession()
    }

    /// The user's own name and picture. Failing to fetch either is not an error worth
    /// surfacing: the Matrix ID is already a usable name, and initials are already a
    /// usable avatar.
    private func loadProfile() async {
        if let name = try? await client.displayName(), !name.isEmpty {
            displayName = name
        }
        avatarURL = try? await client.avatarUrl()
    }

    /// "@boris:matrix.org" → "boris".
    private static func localPart(of userID: String) -> String {
        let withoutSigil = userID.hasPrefix("@") ? String(userID.dropFirst()) : userID
        return String(withoutSigil.prefix { $0 != ":" })
    }

    /// A timeline for one room, or nil if this account is not in it.
    ///
    /// The room list is asked first and the client second, and the second question is not
    /// redundant: a room the user has *just created* exists on the server and in the SDK's
    /// store before the room-list stream has caught up with it, and for that half-second
    /// the list would answer "no such room" about a room whose screen we are opening. See
    /// `createRoom`, which selects it the moment it exists.
    ///
    /// The user's own ID goes down with it because the timeline has to be able to tell a
    /// reaction the user left from one they merely received — see `MessageReaction`.
    public func timeline(forRoomID roomID: String) -> TimelineStore? {
        guard let room = roomList.room(withID: roomID) ?? (try? client.getRoom(roomId: roomID)) else {
            return nil
        }
        return TimelineStore(room: room, ownUserID: userID)
    }

    /// Everything the room-info screen needs, built only when it is opened.
    ///
    /// Made here rather than by `TimelineStore`, which is where it used to come from, for
    /// one reason: notification settings hang off the *account*, not off the room, so this
    /// store needs the `Client` — and the client is the session's to lend. A timeline has
    /// no business holding one.
    public func details(forRoomID roomID: String) -> RoomDetailsStore? {
        guard let room = roomList.room(withID: roomID) ?? (try? client.getRoom(roomId: roomID)) else {
            return nil
        }
        return RoomDetailsStore(room: room, ownUserID: userID, client: client)
    }

    /// Fetches media bytes (a photo, a voice message) on demand.
    public func media() -> MediaLoader {
        MediaLoader(client: client)
    }

    /// This account's encryption, built when the screen that shows it is opened.
    public func recovery() -> RecoveryStore {
        RecoveryStore(encryption: client.encryption())
    }

    /// Proving this device is yours, by comparing pictures with one that already is. Built when
    /// somebody asks to do it — most sessions never will, because most people have one device.
    public func verification() -> VerificationStore {
        VerificationStore(client: client)
    }

    /// Telling the homeserver where to send a push. See `PushRegistration` — and note that the
    /// gateway it needs does not exist yet, which is the one piece of this app that is genuinely
    /// waiting on something outside Xcode.
    public func pushes() -> PushRegistration {
        PushRegistration(client: client)
    }

    /// What this account is keeping on the device, built when the screen that shows it is opened.
    ///
    /// It takes the room list with it, and not for the rooms: clearing the cache means taking the
    /// sync service down and bringing it back up, and the room list is the only thing that holds
    /// one.
    public func storage() -> StorageStore {
        StorageStore(client: client, roomList: roomList, locations: authentication.storageURLs())
    }

    // MARK: - Changing who you are

    /// The name everyone else sees. Applied at once and put back if the server refuses —
    /// the same optimism as `RoomDetailsStore.rename`, and for the same reason: this is a
    /// field the user is looking straight at, and a name that flickers back a second later
    /// is a clearer report of failure than a name that never moved.
    ///
    /// An empty name is refused rather than sent. Matrix allows it, and the result is a
    /// user whose messages are signed with a bare Matrix ID — which is not a name people
    /// choose, it is one they end up with by deleting the field and tapping away.
    ///
    /// These three *throw* rather than parking the refusal in a `failure` field on the
    /// session, which is what they used to do. The session is the app-lifetime object every
    /// screen holds; a settings alert's dismiss state has no business living in it, and the
    /// field was public and settable, so a view could — and did — write a photo-library
    /// error into the model layer. Reporting failure as a typed throw is what `RoomCreation`
    /// already does, and it leaves the alert where the alert belongs.
    public func rename(to newName: String) async throws(AccountActionFailure) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != displayName else { return }

        let previous = displayName
        displayName = trimmed

        do {
            try await client.setDisplayName(name: trimmed)
        } catch {
            Log.session.error("the name would not change: \(String(describing: error), privacy: .public)")
            displayName = previous
            throw .name
        }
    }

    /// The picture, as bytes, exactly as a room's picture goes up — see
    /// `RoomDetailsStore.setPicture` for why it is bytes and not a path on disk.
    public func setPicture(_ data: Data, filename: String) async throws(AccountActionFailure) {
        let info = MediaMetadata.image(data: data, filename: filename)

        do {
            try await client.uploadAvatar(mimeType: info.mimeType, data: data)
            avatarURL = try? await client.avatarUrl()
        } catch {
            Log.session.error("the picture would not change: \(String(describing: error), privacy: .public)")
            throw .picture
        }
    }

    public func removePicture() async throws(AccountActionFailure) {
        let previous = avatarURL
        avatarURL = nil

        do {
            try await client.removeAvatar()
        } catch {
            Log.session.error("the picture would not clear: \(String(describing: error), privacy: .public)")
            avatarURL = previous
            throw .picture
        }
    }

    public func signOut() async {
        authErrorHandle?.cancel()
        authErrorHandle = nil

        await roomList.stop()
        await authentication.signOut(client: client)
    }
}

/// The SDK telling us the server has stopped accepting our token.
///
/// `isSoftLogout` is dropped, and the distinction it draws is one this app cannot act on. A soft
/// logout means the tokens are dead but the encrypted store could be kept and re-attached to a
/// fresh sign-in by the same user — which is a real optimisation and a real screen ("sign back in
/// as Boris"), and Iskra has neither. Treating both as "you are signed out" is the honest
/// simplification: the alternative is a store kept for a flow that does not exist.
private final class AuthErrors: ClientDelegate {
    private let onAuthError: @Sendable () -> Void

    init(onAuthError: @escaping @Sendable () -> Void) {
        self.onAuthError = onAuthError
    }

    func didReceiveAuthError(isSoftLogout: Bool) {
        onAuthError()
    }

    /// The SDK's own note says an embedder that does not run background jobs may leave this empty.
    /// This one does not.
    func onBackgroundTaskErrorReport(taskName: String, error: BackgroundTaskFailureReason) {}
}
