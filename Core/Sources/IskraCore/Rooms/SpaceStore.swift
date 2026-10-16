import Foundation
import Observation
import MatrixRustSDK

/// One room inside a space, as its own screen shows it — a value type, so the SDK's `SpaceRoom`
/// (and the handles behind it) never reach the view.
public struct SpaceRoomSummary: Sendable, Identifiable, Equatable, Hashable {
    public let id: String
    public let name: String
    public let topic: String?
    public let avatarURL: String?
    public let memberCount: Int
    /// A space nested inside this one. Matrix spaces form a tree; a child can itself be a space.
    public let isSpace: Bool

    public init(id: String, name: String, topic: String? = nil, avatarURL: String? = nil,
                memberCount: Int = 0, isSpace: Bool = false) {
        self.id = id
        self.name = name
        self.topic = topic
        self.avatarURL = avatarURL
        self.memberCount = memberCount
        self.isSpace = isSpace
    }
}

/// The rooms inside one space — «пространство», in the app's words.
///
/// A space is a room of a particular type that groups other rooms, and the SDK hands its contents
/// back through a paginated `SpaceRoomList`. This opens that list, pages through it, and projects it
/// into value-type summaries the screen can show — the same division as `RoomListStore`, made for
/// the same reason.
///
/// One store per space screen, made from the session with the space's own room ID.
@MainActor
@Observable
public final class SpaceStore {
    public private(set) var rooms: [SpaceRoomSummary] = []
    public private(set) var isLoading = true

    private let client: Client
    private let spaceID: String

    /// How many pages to pull before showing what we have. A space is usually small; this is a
    /// backstop against a pathologically large one holding the screen blank, not a real limit anyone
    /// meets.
    private static let maxPages = 5

    init(client: Client, spaceID: String) {
        self.client = client
        self.spaceID = spaceID
    }

    public func load() async {
        defer { isLoading = false }

        let service = await client.spaceService()
        guard let list = try? await service.spaceRoomList(spaceId: spaceID) else { return }

        // Page through it. `paginate()` throws at the end of the list as well as on a real failure,
        // so a throw is a reason to stop, not to fail — we show whatever pages did come back.
        for _ in 0..<Self.maxPages {
            guard !Task.isCancelled else { return }
            do {
                try await list.paginate()
            } catch {
                break
            }
        }

        guard !Task.isCancelled else { return }
        let spaceRooms = await list.rooms()
        // The space lists *itself* among its rooms; drop it — you are already looking at it.
        rooms = spaceRooms
            .filter { $0.roomId != spaceID }
            .map(Self.summary(from:))
    }

    static func summary(from room: SpaceRoom) -> SpaceRoomSummary {
        SpaceRoomSummary(id: room.roomId,
                         name: room.displayName,
                         topic: room.topic,
                         avatarURL: room.avatarUrl,
                         memberCount: Int(room.numJoinedMembers),
                         isSpace: room.roomType == .space)
    }
}
