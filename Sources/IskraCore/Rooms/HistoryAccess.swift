import Foundation
import MatrixRustSDK

/// Who may read what was said in a room before they came — `m.room.history_visibility`, in the
/// words a person would use for it.
///
/// Telegram asks the same question of a group as a yes or no ("chat history for new members"), and
/// Matrix asks it in four answers. Three of them are the same yes-or-no at different moments —
/// everything, from the invitation, from joining — and all three are offered, because they are
/// different promises to the people already talking. The fourth, `worldReadable`, is a different
/// thing altogether — anybody may read the room without joining it — and is offered only for a
/// room anybody may walk into, where it promises nothing the open door does not already give away.
///
/// A promise the *server* keeps, and only for what the server can read. In an encrypted room a
/// newcomer gets the events and not the keys to them, so "everything" there means "everything,
/// unreadable" unless somebody shares the keys — the screen says so.
public enum HistoryAccess: String, Sendable, CaseIterable, Identifiable {
    /// Everything said since the room began, to anybody who joins.
    case shared
    /// From the moment they were invited.
    case invited
    /// From the moment they joined.
    case joined
    /// To anybody at all, members or not.
    case worldReadable

    public var id: String { rawValue }

    /// What is offered: all four in an open room, the first three in any other.
    public static func choices(isPublic: Bool) -> [HistoryAccess] {
        isPublic ? allCases : [.shared, .invited, .joined]
    }

    init(_ sdk: RoomHistoryVisibility) {
        switch sdk {
        case .invited: self = .invited
        case .joined: self = .joined
        case .worldReadable: self = .worldReadable
        // Shared is the spec's default for a room that says nothing, and a custom value is a
        // server's own extension this app cannot describe; shown as the default, it is at worst
        // a sentence about the room's past, not a door left open.
        case .shared, .custom: self = .shared
        }
    }

    var sdk: RoomHistoryVisibility {
        switch self {
        case .shared: .shared
        case .invited: .invited
        case .joined: .joined
        case .worldReadable: .worldReadable
        }
    }
}
