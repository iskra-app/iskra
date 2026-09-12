import Foundation
import MatrixRustSDK

/// Whether you are *in* this conversation, or merely being asked to be.
///
/// The room list has always carried invitations and never said so. The SDK's filter is `.nonLeft`
/// — which is right, an invitation you have not answered is not a room you have left — so an
/// invited room arrived in the list looking exactly like a joined one. It had no last message, so
/// it sank to the bottom; opening it showed an empty conversation; typing into it sent a message
/// the server refused, because you are not in the room. Nothing anywhere said "somebody has asked
/// you to join this". The push notification this app sends for an invitation — "Аня приглашает вас
/// в чат" — led straight into that.
///
/// Only the two states the list can be in. `.left` and `.banned` are filtered out before they get
/// here, and `.knocked` is a door this app does not knock on.
public enum RoomMembership: Sendable, Equatable, Hashable {
    case joined
    case invited

    init?(_ membership: Membership) {
        switch membership {
        case .joined: self = .joined
        case .invited: self = .invited
        // Filtered out by `.nonLeft`, or a flow this app has no screen for. A room in one of these
        // states has no business in the list, and guessing at one would be worse than dropping it.
        default: return nil
        }
    }
}

/// Whether a conversation is protected, said in a way a person can act on.
///
/// The UI never shows the words "E2EE", "Megolm" or "encryption state". It shows a
/// lock and a sentence. This enum is the seam between the protocol's vocabulary and
/// the user's.
public enum PrivacyStatus: Sendable, Equatable, Hashable {
    /// Only the people in the conversation can read it.
    case protected
    /// The server can read it. True for public rooms and legacy unencrypted ones.
    case notProtected
    /// We have not synced enough to know yet. Never claim protection we cannot see.
    case unknown

    init(_ state: EncryptionState) {
        switch state {
        case .encrypted: self = .protected
        case .notEncrypted: self = .notProtected
        case .unknown: self = .unknown
        }
    }

    /// Plain language, no jargon, safe to put straight on screen.
    public var explanation: LocalizedStringResource {
        switch self {
        case .protected: CoreStrings.Privacy.protected
        case .notProtected: CoreStrings.Privacy.notProtected
        case .unknown: CoreStrings.Privacy.unknown
        }
    }

    public var iconName: String {
        switch self {
        case .protected: "lock.fill"
        case .notProtected: "lock.open"
        case .unknown: "lock.badge.questionmark"
        }
    }
}

/// A row in the conversation list. A snapshot: cheap to diff, safe to hand to SwiftUI.
public struct RoomSummary: Sendable, Identifiable, Equatable, Hashable {
    public let id: String
    public let name: String
    public let avatarURL: String?
    /// A chat with one person, a chat with several, or a space. See `RoomKind` — and note that
    /// this says how the room was *made*, not how many people are in it today.
    public let kind: RoomKind
    public let privacy: PrivacyStatus
    /// Unread messages. Drives the badge.
    public let unreadCount: Int
    /// Unread messages that mention the user directly. Drives the badge's colour.
    public let mentionCount: Int
    public let lastMessage: String?
    public let lastActivity: Date?

    /// A space, not a chat. The list shows it as an ordinary row — a square-cornered avatar and
    /// a tap that opens the space's rooms rather than a conversation — so what tells the two
    /// apart has to travel on the summary. It travels as `kind`; this is the short way to ask.
    public var isSpace: Bool { kind == .space }

    /// A conversation with one person, as opposed to a group. Says how the room was made — a
    /// group with two people in it is still a group, and a personal chat stays one when a third
    /// person is invited.
    public var isDirectMessage: Bool { kind == .direct }

    /// Pinned to the top of the list. This is the Matrix `m.favourite` tag, so it syncs across the
    /// user's devices; the list sorts favourites above everything else.
    public let isFavourite: Bool

    /// Archived. This is the Matrix `m.lowpriority` tag — the nearest thing the protocol has to an
    /// archive. A low-priority room is filtered out of the main list and shown only on the archive
    /// screen; its history is untouched (it is not left).
    public let isLowPriority: Bool

    /// The user marked this read conversation unread by hand. Distinct from `unreadCount`, which
    /// counts actual unread messages — a room can have zero unread messages and still be flagged.
    public let isMarkedUnread: Bool

    /// Joined, or invited and waiting for an answer.
    public let membership: RoomMembership

    /// Who asked you in, when somebody has. Their display name, or their Matrix ID where they have
    /// not chosen one — flattened to a string on purpose: `RoomMember` is an SDK *class handle*,
    /// and this is a value type that goes to SwiftUI.
    ///
    /// Genuinely optional even for an invitation: the SDK's own note on `RoomInfo.inviter` says it
    /// can be missing when the invite event itself is not in the store.
    public let invitedBy: String?

    public var hasUnread: Bool { unreadCount > 0 || isMarkedUnread }
    public var isMentioned: Bool { mentionCount > 0 }
    public var isInvitation: Bool { membership == .invited }
    /// Pinned to the top. A friendlier name than "favourite" for the one place the rest of the app
    /// reasons about it — the row is pinned, the tag underneath happens to be `m.favourite`.
    public var isPinned: Bool { isFavourite }
    /// Archived away from the main list. The tag underneath is `m.lowpriority`.
    public var isArchived: Bool { isLowPriority }

    /// Built by hand — for tests, and for anything that wants a row without an SDK behind it.
    ///
    /// A value type with no way to make one is a value type only the SDK can talk about, and the
    /// ordering rules below (invitations first, then recency) are exactly the kind of thing that
    /// should be pinned without standing up a homeserver to do it.
    public init(id: String,
                name: String,
                avatarURL: String? = nil,
                kind: RoomKind = .group,
                privacy: PrivacyStatus = .protected,
                unreadCount: Int = 0,
                mentionCount: Int = 0,
                lastMessage: String? = nil,
                lastActivity: Date? = nil,
                isFavourite: Bool = false,
                isLowPriority: Bool = false,
                isMarkedUnread: Bool = false,
                membership: RoomMembership = .joined,
                invitedBy: String? = nil) {
        self.id = id
        self.name = name
        self.avatarURL = avatarURL
        self.kind = kind
        self.privacy = privacy
        self.unreadCount = unreadCount
        self.mentionCount = mentionCount
        self.lastMessage = lastMessage
        self.lastActivity = lastActivity
        self.isFavourite = isFavourite
        self.isLowPriority = isLowPriority
        self.isMarkedUnread = isMarkedUnread
        self.membership = membership
        self.invitedBy = invitedBy
    }

    init?(info: RoomInfo, ownUserID: String, lastMessage: String?, lastActivity: Date?) {
        // A room that is neither joined nor invited is not a row. Failing here rather than
        // defaulting to `.joined` is the point: a left or banned room rendered as an ordinary chat
        // is exactly the class of bug this type is being introduced to end.
        guard let membership = RoomMembership(info.membership) else { return nil }
        self.membership = membership

        self.id = info.id
        // Both the name and the picture fall back to the other person in a personal chat, and
        // they fall back together — see `RoomInfo.title` and `RoomInfo.pictureURL`. They used to
        // disagree: the name knew about the heroes and the picture did not, so a chat with
        // somebody who has a photograph showed their name beside a circle of initials.
        self.name = info.title(besides: ownUserID)
        self.avatarURL = info.pictureURL(besides: ownUserID)
        self.kind = info.kind
        self.privacy = PrivacyStatus(info.encryptionState)
        self.unreadCount = Int(info.notificationCount)
        self.mentionCount = Int(info.highlightCount)
        self.lastMessage = lastMessage
        self.lastActivity = lastActivity
        self.isFavourite = info.isFavourite
        self.isLowPriority = info.isLowPriority
        self.isMarkedUnread = info.isMarkedUnread
        self.invitedBy = info.inviter.map { $0.displayName ?? $0.userId }
    }
}
