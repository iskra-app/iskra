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

    private let client: Client
    private let authentication: AuthenticationService

    public init(client: Client, authentication: AuthenticationService) {
        self.client = client
        self.authentication = authentication
        self.userID = (try? client.userId()) ?? ""
        self.roomList = RoomListStore(client: client)
        self.search = SearchStore(client: client)
    }

    /// Starts the sync loop. Everything else follows from this.
    public func start() async throws {
        try await roomList.start()
    }

    /// A timeline for one room, or nil if the room list has not seen it yet.
    public func timeline(forRoomID roomID: String) -> TimelineStore? {
        guard let room = roomList.room(withID: roomID) else { return nil }
        return TimelineStore(room: room)
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
