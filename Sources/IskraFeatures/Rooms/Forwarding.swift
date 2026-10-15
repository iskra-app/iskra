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

    /// The words written under a forward in the share sheet, sent after it as a message of their own
    /// — Telegram's order: what is being passed on, then what you have to say about it.
    public func comment(_ text: String, to roomID: String) async {
        await session.sendText(text, toRoomID: roomID)
    }
}

public extension EnvironmentValues {
    /// The forward capability. Nil until a session is up.
    @Entry var forwarding: Forwarding?
    /// Live location sharing for the open account — see `LiveLocationSharer`. Nil until a session is up.
    @Entry var liveLocation: LiveLocationSharer?
}
