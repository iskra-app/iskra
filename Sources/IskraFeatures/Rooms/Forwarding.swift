import SwiftUI
import IskraCore

/// The forward capability, handed down so a message's menu can send it into another room without
/// the row being wired to the whole session. It is the one piece of message UI that reaches across
/// rooms — everything else in a bubble is about the room it is in — so it travels through the
/// environment the way the block list does.
@MainActor
@Observable
public final class Forwarding {
    private let session: UserSession

    public init(session: UserSession) {
        self.session = session
    }

    /// Where a message can be forwarded to: the joined conversations. Spaces are not chats and
    /// invitations are not rooms you are in, so neither is a destination.
    public var destinations: [RoomSummary] {
        session.roomList.rooms.filter { !$0.isInvitation && !$0.isSpace }
    }

    public func forward(_ message: Message, to roomID: String) async -> Bool {
        await session.forward(message, toRoomID: roomID)
    }
}

public extension EnvironmentValues {
    /// The forward capability. Nil until a session is up.
    @Entry var forwarding: Forwarding?
}
