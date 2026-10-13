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

    /// What a generated stand-in face is computed from when there is no picture — the room's own
    /// ID, or the other person's in a personal chat. See `RoomInfo.avatarSeed(besides:)`.
    public let avatarSeed: String

    /// The few members the server names as a description of this room. Empty unless this is a
    /// group: a personal chat already borrows the other person's picture, and a space is not a
    /// collection of people. See `RoomInfo.faces(besides:)`.
    public let faces: [RoomFace]
    /// A chat with one person, a chat with several, or a space. See `RoomKind` — and note that
    /// this says how the room was *made*, not how many people are in it today.
    public let kind: RoomKind
    public let privacy: PrivacyStatus
    /// Unread messages that would have notified — the SDK counts them against the user's own
    /// notification settings. Drives the number in the badge.
    public let unreadCount: Int
    /// Unread messages that mention the user directly. Drives the badge's colour.
    public let mentionCount: Int
    /// Unread messages, whatever the notification settings say. A muted room notifies nobody and
    /// still has new messages in it, so this is what a muted room has instead of a count: the
    /// list shows a plain dot rather than a number.
    public let unreadMessageCount: Int
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

    /// This room has been silenced *by name* — `RoomNotificationMode.mute`, set on the chat's own
    /// info screen and stored as a push rule against this room ID.
    ///
    /// Read from `RoomInfo.cachedUserDefinedNotificationMode`, which costs nothing: it rides along
    /// with the room info the list is already receiving, so the badge does not need a second call
    /// per row to know how loud the room is.
    ///
    /// Two things it is not, and both are deliberate.
    ///
    /// It is not "this room will not notify you". A room that inherits a muted *account* default
    /// has no rule of its own, so the SDK caches nothing and this is false — which is the honest
    /// answer to the question actually being asked, because the grey badge is meant to say "you
    /// silenced this one", not "the account is quiet". An account muted everywhere would otherwise
    /// draw a list in which every badge was grey and the colour meant nothing.
    ///
    /// And it is not the same as having no number to show. A muted room counts no notifications
    /// and falls back to a dot — see `hasUnreadCount` — but so does a room flagged unread by hand,
    /// which nobody has silenced. Inferring the mute from the missing count would paint that one
    /// grey too.
    public let isMuted: Bool

    /// Joined, or invited and waiting for an answer.
    public let membership: RoomMembership

    /// Who asked you in, when somebody has. Their display name, or their Matrix ID where they have
    /// not chosen one — flattened to a string on purpose: `RoomMember` is an SDK *class handle*,
    /// and this is a value type that goes to SwiftUI.
    ///
    /// Genuinely optional even for an invitation: the SDK's own note on `RoomInfo.inviter` says it
    /// can be missing when the invite event itself is not in the store.
    public let invitedBy: String?

    /// Unread reactions, told apart from unread messages.
    ///
    /// The SDK has no count of them; it has to be worked out. `ReactionPushRule` makes every
    /// reaction *notify*, so each one lands in `unreadCount` — and a reaction is not a message, so
    /// none lands in `unreadMessageCount`. What notified beyond the messages there are is, give or
    /// take, reactions. It errs towards too few, never too many: a room that notifies only on
    /// mentions has more messages than notifications, and its reactions read as nought, which is
    /// a missing heart rather than a heart for nothing.
    ///
    /// It used to be no distinction at all: a reaction put a number on the chat's badge, the chat
    /// opened on nothing new, and the number meant nothing anybody could find.
    public var unreadReactionCount: Int { max(0, unreadCount - unreadMessageCount) }

    /// Unread messages that would have notified — `unreadCount` without the reactions in it.
    /// What the number on the badge says.
    public var unreadNotifyingMessages: Int { unreadCount - unreadReactionCount }

    public var hasUnreadReactions: Bool { unreadReactionCount > 0 }

    /// Something to read — messages, or a flag set by hand. Reactions alone are not this: they
    /// have a mark of their own (`hasUnreadReactions`).
    public var hasUnread: Bool { unreadNotifyingMessages > 0 || unreadMessageCount > 0 || isMarkedUnread }
    /// There is a number to show. A muted room, or a room flagged unread by hand, has unread
    /// *something* and nothing to count — it gets a dot instead, and asking this is how the row
    /// tells the two apart.
    public var hasUnreadCount: Bool { unreadNotifyingMessages > 0 }
    public var isMentioned: Bool { mentionCount > 0 }

    /// How loudly the unread badge should say so — three answers, and the view turns them into
    /// three colours.
    ///
    /// It lives here rather than in the row because it is a fact about the room and not about
    /// paint: `IskraCore` is not allowed to know what colour an accent is, and the row should not
    /// be the place that decides what "muted" means. Same division as `PrivacyStatus`, and it is
    /// what lets the rule be pinned in a test without standing up SwiftUI. See `UnreadEmphasis`.
    ///
    /// Being named is no longer one of the answers. It used to be a red badge; it is now an "@"
    /// drawn *beside* the badge, and the badge keeps the colour of the room — see `isMentioned`.
    public var unreadEmphasis: UnreadEmphasis {
        isMuted ? .muted : .ordinary
    }
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
                unreadMessageCount: Int = 0,
                mentionCount: Int = 0,
                lastMessage: String? = nil,
                lastActivity: Date? = nil,
                isFavourite: Bool = false,
                isLowPriority: Bool = false,
                isMarkedUnread: Bool = false,
                isMuted: Bool = false,
                membership: RoomMembership = .joined,
                invitedBy: String? = nil,
                avatarSeed: String? = nil,
                faces: [RoomFace] = []) {
        self.id = id
        self.name = name
        self.avatarURL = avatarURL
        self.avatarSeed = avatarSeed ?? id
        self.faces = faces
        self.kind = kind
        self.privacy = privacy
        self.unreadCount = unreadCount
        self.unreadMessageCount = unreadMessageCount
        self.mentionCount = mentionCount
        self.lastMessage = lastMessage
        self.lastActivity = lastActivity
        self.isFavourite = isFavourite
        self.isLowPriority = isLowPriority
        self.isMarkedUnread = isMarkedUnread
        self.isMuted = isMuted
        self.membership = membership
        self.invitedBy = invitedBy
    }

    init?(info: RoomInfo,
          ownUserID: String,
          lastMessage: String?,
          lastActivity: Date?,
          isMuted: Bool = false) {
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
        self.avatarSeed = info.avatarSeed(besides: ownUserID)
        // Only a group gathers a cluster. A personal chat falls back to the other person's
        // picture a line above this, and a space is a shelf of rooms rather than a set of people.
        self.faces = info.kind == .group ? info.faces(besides: ownUserID) : []
        self.kind = info.kind
        self.privacy = PrivacyStatus(info.encryptionState)
        // `numUnread*`, not `notificationCount`/`highlightCount`.
        //
        // The latter pair is what the homeserver sent in `unread_notifications`, and under
        // sliding sync the server does not send it: it stays at zero for every room forever, so
        // every badge in the list was drawn `if 0 > 0` and no chat ever looked unread. The
        // `numUnread*` fields are the SDK's own, computed locally from read receipts against the
        // user's notification settings, and they are what Element X reads for the same badge.
        self.unreadCount = Int(info.numUnreadNotifications)
        self.mentionCount = Int(info.numUnreadMentions)
        self.unreadMessageCount = Int(info.numUnreadMessages)
        self.lastMessage = lastMessage
        self.lastActivity = lastActivity
        self.isFavourite = info.isFavourite
        self.isLowPriority = info.isLowPriority
        self.isMarkedUnread = info.isMarkedUnread
        // Two sources, and the room is muted if either says so.
        //
        // The argument is the list's own answer — `RoomListStore` reads the push rules once and
        // keeps the set, which is the reliable half. `cachedUserDefinedNotificationMode` is the
        // SDK's, and the word *cached* is load-bearing: it is nil until something has asked the
        // server for this room's rule, so on a cold launch it knows almost nothing. It is still
        // worth reading, because it is the half that is right *first* — opening a chat's info
        // screen warms it, and a mute made there shows in the list before the set is reloaded.
        //
        // Neither alone was enough. The cache alone left every muted room in the app drawn in the
        // accent until the day its info screen happened to be opened.
        self.isMuted = isMuted || info.cachedUserDefinedNotificationMode == .mute
        self.invitedBy = info.inviter.map { $0.displayName ?? $0.userId }
    }
}

/// How loudly an unread badge says there is something waiting.
///
/// Three answers and not a colour among them, because this is `IskraCore`: the row in the chat
/// list turns each one into paint, and that is the only place that knows what the accent is.
///
/// The ordering is a hierarchy, and `RoomSummary.unreadEmphasis` reads it top down. A mention in a
/// muted room is still a mention — silencing a room is a statement about its chatter, not about
/// being named in it, and Matrix agrees: `.m.rule.is_user_mention` fires through a muted room's
/// own rule. So a room can be grey on Tuesday and red on Wednesday without anything having been
/// changed.
public enum UnreadEmphasis: String, Sendable, CaseIterable {
    /// Ordinary unread messages, in the colour the user chose the app to be.
    case ordinary

    /// A room the user silenced by name. Grey — and the grey is the point rather than the absence
    /// of one: it is the badge saying "yes, there is something here, and you already told me you
    /// did not want to hear about it".
    case muted
}
