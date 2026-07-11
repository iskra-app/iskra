import Foundation
import MatrixRustSDK

/// Whether a conversation is protected, said in a way a person can act on.
///
/// The UI never shows the words "E2EE", "Megolm" or "encryption state". It shows a
/// lock and a sentence. This enum is the seam between the protocol's vocabulary and
/// the user's.
public enum PrivacyStatus: Sendable, Equatable {
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
public struct RoomSummary: Sendable, Identifiable, Equatable {
    public let id: String
    public let name: String
    public let avatarURL: String?
    public let isDirectMessage: Bool
    public let privacy: PrivacyStatus
    /// Unread messages. Drives the badge.
    public let unreadCount: Int
    /// Unread messages that mention the user directly. Drives the badge's colour.
    public let mentionCount: Int
    public let lastMessage: String?
    public let lastActivity: Date?

    public var hasUnread: Bool { unreadCount > 0 }
    public var isMentioned: Bool { mentionCount > 0 }

    init(info: RoomInfo, lastMessage: String?, lastActivity: Date?) {
        self.id = info.id
        // A room with no name is normal in Matrix (most DMs have none); fall back to
        // whoever is in it rather than showing a raw room ID to a human.
        self.name = info.displayName ?? info.heroes.first?.displayName ?? String(core: CoreStrings.Room.untitled)
        self.avatarURL = info.avatarUrl
        self.isDirectMessage = info.isDm
        self.privacy = PrivacyStatus(info.encryptionState)
        self.unreadCount = Int(info.notificationCount)
        self.mentionCount = Int(info.highlightCount)
        self.lastMessage = lastMessage
        self.lastActivity = lastActivity
    }
}
