import Foundation
import UserNotifications
import IskraCore

/// The number on the app's icon.
///
/// It is the one part of the app that is read while the app is closed, and the only number in it
/// that has to agree with something the user can count for themselves — so it counts the same
/// things the chat list marks: unread messages, and invitations, which are unread in the way that
/// matters even though nobody has said anything in them yet.
///
/// Spaces are left out. A space is a folder of rooms, and its unread count is the sum of rooms
/// already counted here — adding it would show every message twice.
@MainActor
public enum AppBadge {
    /// What the icon should say, given the conversations as they are now.
    ///
    /// Pure and `internal` so the arithmetic can be pinned in a test: the badge itself cannot be
    /// read back from `UNUserNotificationCenter` in any way a test could check, and "the number is
    /// wrong" is a bug people notice immediately and report vaguely.
    static func count(for rooms: [RoomSummary]) -> Int {
        rooms.reduce(0) { total, room in
            if room.isSpace { return total }

            // An invitation counts once, whatever is inside it. There is no "unread" in a room
            // nobody has joined, and one waiting invitation is one thing to attend to.
            if room.isInvitation { return total + 1 }

            return total + room.unreadCount
        }
    }

    /// Puts that number on the icon.
    ///
    /// Failures are logged and nothing else. A badge that would not set is a wrong number on an
    /// icon; an alert about a badge would be a worse thing than the wrong number.
    ///
    /// - Parameter account: whose rooms these are. The count is written down as that account's, and
    ///   the icon shows every account's added together — see `UnreadCounts`. Nil (the demo) shows
    ///   this list's count alone and writes nothing down.
    public static func update(for rooms: [RoomSummary], account: String? = nil) {
        guard let account else {
            set(count(for: rooms))
            return
        }
        set(UnreadCounts.set(count(for: rooms), forAccount: account))
    }

    /// One account signed out: its number comes off the icon, everybody else's stays.
    public static func forget(account: String) {
        set(UnreadCounts.forget(account: account))
    }

    /// Takes the number off, for a sign-out. Left alone it would keep somebody else's unread count
    /// on the icon of an app nobody is signed into.
    public static func clear() {
        UnreadCounts.forgetAll()
        set(0)
    }

    private static func set(_ count: Int) {
        UNUserNotificationCenter.current().setBadgeCount(count) { error in
            guard let error else { return }
            Log.push.error("the icon badge could not be set: \(Log.describe(error), privacy: .public)")
        }
    }
}
