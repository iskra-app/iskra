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

    /// Set when the server would not take a new name or a new picture. `var`, because the
    /// alert that shows it has to be able to put it back.
    public var failure: AccountActionFailure?

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
        self.displayName = Self.localPart(of: userID)
        self.roomList = RoomListStore(client: client)
        self.search = SearchStore(client: client)
    }

    /// Starts the sync loop. Everything else follows from this.
    public func start() async throws {
        await loadProfile()
        try await roomList.start()
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

    /// The name of *this* device, as the rest of the account sees it. The one true thing
    /// the sessions screen can say — see `ROADMAP.md`, stage 6, on why it cannot list the
    /// others.
    public var deviceID: String {
        (try? client.deviceId()) ?? ""
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
    public func rename(to newName: String) async {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != displayName else { return }

        let previous = displayName
        displayName = trimmed

        do {
            try await client.setDisplayName(name: trimmed)
        } catch {
            Log.session.error("the name would not change: \(error)")
            displayName = previous
            failure = .name
        }
    }

    /// The picture, as bytes, exactly as a room's picture goes up — see
    /// `RoomDetailsStore.setPicture` for why it is bytes and not a path on disk.
    public func setPicture(_ data: Data, filename: String) async {
        let info = MediaMetadata.image(data: data, filename: filename)

        do {
            try await client.uploadAvatar(mimeType: info.mimeType, data: data)
            avatarURL = try? await client.avatarUrl()
        } catch {
            Log.session.error("the picture would not change: \(error)")
            failure = .picture
        }
    }

    public func removePicture() async {
        let previous = avatarURL
        avatarURL = nil

        do {
            try await client.removeAvatar()
        } catch {
            Log.session.error("the picture would not clear: \(error)")
            avatarURL = previous
            failure = .picture
        }
    }

    public func signOut() async {
        await roomList.stop()
        await authentication.signOut(client: client)
    }
}
