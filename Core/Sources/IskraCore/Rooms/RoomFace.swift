import Foundation

/// One person, as much of them as a row in the chat list needs: who they are, what to call them,
/// and where their picture is if they have one.
///
/// Flattened out of the SDK's `RoomHero` on purpose. A hero is the server's own shorthand for
/// "who is in this room" — the two or three members it sends so a client can describe a room that
/// has no name of its own — and it arrives free, riding along with the room info the list is
/// already receiving. Asking for the membership list instead would be a call per row.
public struct RoomFace: Sendable, Equatable, Hashable, Identifiable {
    /// The Matrix user ID. This is what a generated face is seeded from, so it has to be the
    /// identifier and not the display name — see `Blobatar`.
    public let id: String
    public let name: String
    public let avatarURL: String?

    public init(id: String, name: String, avatarURL: String? = nil) {
        self.id = id
        self.name = name
        self.avatarURL = avatarURL
    }
}
