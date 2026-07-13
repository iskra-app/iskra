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

    private let client: Client
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

    /// A timeline for one room, or nil if the room list has not seen it yet.
    ///
    /// The user's own ID goes down with it because the timeline has to be able to tell a
    /// reaction the user left from one they merely received — see `MessageReaction`.
    public func timeline(forRoomID roomID: String) -> TimelineStore? {
        guard let room = roomList.room(withID: roomID) else { return nil }
        return TimelineStore(room: room, ownUserID: userID)
    }

    /// Fetches media bytes (a photo, a voice message) on demand.
    public func media() -> MediaLoader {
        MediaLoader(client: client)
    }

    public func signOut() async {
        await roomList.stop()
        await authentication.signOut(client: client)
    }
}
