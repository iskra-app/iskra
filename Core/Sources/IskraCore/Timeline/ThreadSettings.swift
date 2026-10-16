import Foundation

/// Where a room keeps answers in threads — Settings → Chats. Two questions, asked separately:
///
/// - **In which rooms** there are threads at all (`Shown`): always, never, or only in rooms of
///   more than `largeRoom` people, which is the default. In a big room threads are what keeps one
///   discussion from drowning the rest; among a dozen friends they mostly fold away a reply
///   somebody would rather have seen.
/// - **Whether the answers also leave the room's own timeline** (`hidesReplies`). Off by default:
///   a thread is a line under its message that opens the discussion, and the answers are *also*
///   where they were written, so nobody who never taps a thread misses one. On, they live only in
///   the thread — Element's and Telegram's comments.
///
/// Personal chats never have threads, whichever is chosen: between two people a thread is a second
/// conversation with the same person, and the one room they already have reads better top to
/// bottom. Read when a room's timeline is opened: a timeline cannot change its focus while open.
public enum ThreadSettings {
    public enum Shown: String, CaseIterable, Sendable {
        case always
        case inLargeRooms
        case never
    }

    public static let shownKey = "chats.threads.shown"
    public static let shownByDefault: Shown = .inLargeRooms
    public static let hidesRepliesKey = "chats.threads.hidesReplies"
    public static let hidesRepliesByDefault = false

    /// "A big room": more people than this.
    public static let largeRoom = 100

    /// The single on/off switch this replaced. Read once, so that somebody who had switched
    /// threads off does not find them back on.
    static let legacyIsEnabledKey = "chats.threads"

    public static let keys = [shownKey, hidesRepliesKey, legacyIsEnabledKey]

    public static func shown(_ defaults: UserDefaults = .standard) -> Shown {
        if let raw = defaults.string(forKey: shownKey), let shown = Shown(rawValue: raw) { return shown }
        if defaults.object(forKey: legacyIsEnabledKey) as? Bool == false { return .never }
        return shownByDefault
    }

    public static func hidesReplies(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: hidesRepliesKey) as? Bool ?? hidesRepliesByDefault
    }

    /// Whether a room of this kind and size has threads.
    public static func usesThreads(kind: RoomKind, memberCount: Int,
                                   _ defaults: UserDefaults = .standard) -> Bool {
        usesThreads(kind: kind, memberCount: memberCount, shown: shown(defaults))
    }

    public static func usesThreads(kind: RoomKind, memberCount: Int, shown: Shown) -> Bool {
        guard kind != .direct else { return false }
        return switch shown {
        case .always: true
        case .inLargeRooms: memberCount > largeRoom
        case .never: false
        }
    }
}
