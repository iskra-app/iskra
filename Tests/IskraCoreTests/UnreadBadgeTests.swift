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

    @Test("a mention colours the badge red")
    func mention() {
        let room = RoomSummary.preview(unreadCount: 3, mentionCount: 1, unreadMessageCount: 3)
        #expect(room.isMentioned)
        #expect(room.hasUnreadCount)
    }
}

private extension RoomSummary {
    static func preview(unreadCount: Int = 0,
                        mentionCount: Int = 0,
                        unreadMessageCount: Int = 0,
                        isMarkedUnread: Bool = false) -> RoomSummary {
        RoomSummary(id: "!room:example.org",
                    name: "Room",
                    unreadCount: unreadCount,
                    unreadMessageCount: unreadMessageCount,
                    mentionCount: mentionCount,
                    isMarkedUnread: isMarkedUnread)
    }
}
