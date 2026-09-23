import Testing
@testable import IskraCore

/// What the chat list draws beside a room, and it is three different things.
///
/// The bug these pin: every count came off `RoomInfo.notificationCount`, which is the homeserver's
/// `unread_notifications` — and under sliding sync the server never sends it. It was zero for
/// every room in the app, so `unreadCount > 0` was false everywhere and no chat ever looked
/// unread, however many messages were waiting in it.
@Suite("Unread badges")
struct UnreadBadgeTests {
    @Test("messages that would notify are a number")
    func notificationsCount() {
        let room = RoomSummary.preview(unreadCount: 12, unreadMessageCount: 12)
        #expect(room.hasUnread)
        #expect(room.hasUnreadCount)
    }

    @Test("a muted room has unread messages and nothing to count")
    func mutedRoomShowsADot() {
        // Muted: the SDK counts the messages, and counts no notifications for them.
        let room = RoomSummary.preview(unreadCount: 0, unreadMessageCount: 4)
        #expect(room.hasUnread)
        #expect(!room.hasUnreadCount, "a dot, not a badge with 0 written in it")
    }

    @Test("marked unread by hand is unread with nothing in it")
    func markedUnread() {
        let room = RoomSummary.preview(isMarkedUnread: true)
        #expect(room.hasUnread)
        #expect(!room.hasUnreadCount)
    }

    @Test("a read room is silent")
    func readRoom() {
        let room = RoomSummary.preview()
        #expect(!room.hasUnread)
        #expect(!room.hasUnreadCount)
    }

    /// A mention is an "@" beside the badge now, not a red badge — so the badge keeps the room's
    /// own colour and the mention is a separate fact.
    @Test("a mention is its own mark, and the badge keeps the room's colour")
    func mention() {
        let room = RoomSummary.preview(unreadCount: 3, mentionCount: 1, unreadMessageCount: 3)
        #expect(room.isMentioned)
        #expect(room.hasUnreadCount)
        #expect(room.unreadEmphasis == .ordinary)
    }

    /// The three colours, and the order they beat each other in.
    @Test("an ordinary unread chat wears the accent")
    func ordinaryIsTheAccent() {
        let room = RoomSummary.preview(unreadCount: 3, unreadMessageCount: 3)
        #expect(room.unreadEmphasis == .ordinary)
    }

    @Test("a silenced chat wears grey")
    func silencedIsGrey() {
        let room = RoomSummary.preview(unreadMessageCount: 4, isMuted: true)
        #expect(room.hasUnread)
        #expect(room.unreadEmphasis == .muted)
    }

    /// Silencing a room is a statement about its chatter, not about being named in it — and Matrix
    /// agrees, because `.m.rule.is_user_mention` fires through a muted room's own rule. So the
    /// "@" survives the mute, beside a badge that stays grey.
    @Test("being named in a silenced chat is still being named")
    func aMentionBeatsTheMute() {
        let room = RoomSummary.preview(mentionCount: 1, unreadMessageCount: 4, isMuted: true)
        #expect(room.isMentioned)
        #expect(room.unreadEmphasis == .muted)
    }

    /// The one that made this worth a stored field rather than an inference. A muted room has
    /// unread messages and no count, and so does a room flagged unread by hand — reading the mute
    /// off the missing number would have painted the hand-flagged one grey as well, and said the
    /// user had silenced a chat they had in fact just told the app to keep in front of them.
    @Test("marked unread by hand is not the same as silenced")
    func markedUnreadIsNotMuted() {
        let room = RoomSummary.preview(isMarkedUnread: true)
        #expect(room.hasUnread)
        #expect(!room.hasUnreadCount, "nothing to count — the same shape a muted room has")
        #expect(room.unreadEmphasis == .ordinary, "nobody silenced this one")
    }
}

private extension RoomSummary {
    static func preview(unreadCount: Int = 0,
                        mentionCount: Int = 0,
                        unreadMessageCount: Int = 0,
                        isMarkedUnread: Bool = false,
                        isMuted: Bool = false) -> RoomSummary {
        RoomSummary(id: "!room:example.org",
                    name: "Room",
                    unreadCount: unreadCount,
                    unreadMessageCount: unreadMessageCount,
                    mentionCount: mentionCount,
                    isMarkedUnread: isMarkedUnread,
                    isMuted: isMuted)
    }
}
