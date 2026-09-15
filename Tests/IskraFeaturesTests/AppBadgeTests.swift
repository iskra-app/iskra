import Testing
@testable import IskraCore
@testable import IskraFeatures

/// The number on the icon.
///
/// Pinned because it is the one number in the app that somebody can check by counting, and a badge
/// that says three over a list with two unread messages is a bug reported as "notifications are
/// broken" — which sends whoever reads that report to entirely the wrong place.
@MainActor
struct AppBadgeTests {
    private func room(id: String,
                      unread: Int = 0,
                      kind: RoomKind = .direct,
                      membership: RoomMembership = .joined) -> RoomSummary {
        RoomSummary(id: id,
                    name: id,
                    kind: kind,
                    unreadCount: unread,
                    membership: membership)
    }

    @Test("an empty list asks for no badge")
    func nothingUnreadIsNoBadge() {
        #expect(AppBadge.count(for: []) == 0)
        #expect(AppBadge.count(for: [room(id: "!a")]) == 0)
    }

    @Test("unread messages are added up across conversations")
    func unreadMessagesAreSummed() {
        #expect(AppBadge.count(for: [room(id: "!a", unread: 2), room(id: "!b", unread: 3)]) == 5)
    }

    @Test("an invitation counts once, whatever is inside it")
    func invitationsCountOnce() {
        // Nobody has joined, so there is nothing to have read — but one waiting invitation is one
        // thing to attend to, and an icon that ignored it would be lying by omission.
        let invitation = room(id: "!c", unread: 0, membership: .invited)
        #expect(AppBadge.count(for: [invitation]) == 1)
        #expect(AppBadge.count(for: [room(id: "!a", unread: 2), invitation]) == 3)
    }

    @Test("a space is a folder, not a conversation")
    func spacesAreNotCounted() {
        // A space's unread count is the sum of rooms already counted here. Adding it would show
        // every message in it twice.
        #expect(AppBadge.count(for: [room(id: "!s", unread: 7, kind: .space)]) == 0)
    }
}
