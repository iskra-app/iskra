import Foundation
import MatrixRustSDK

/// How far along a message we sent has got. Only ever shown on our own messages.
public enum DeliveryStatus: Sendable, Equatable {
    case sending
    case sent
    /// Someone else in the room has read it.
    case read
    /// Sending failed. The SDK's send queue will retry, so this is not the end.
    case failed
}

/// What a message actually is. The UI switches on this to pick a bubble.
public enum MessageKind: Sendable, Equatable {
    case text(String)
    case emote(String)
    case notice(String)
    case image(Attachment)
    case video(Attachment)
    /// A round video message, recorded in the chat. See `VideoNote`.
    case videoNote(Attachment)
    case voice(Attachment, waveform: [Float])
    case audio(Attachment)
    case file(Attachment)
    /// The message is there, but this device was never given the key to read it.
    case unreadable
    case deleted
    /// Something we do not render yet. Better an honest blank than a wrong guess.
    case unsupported
}

/// A downloadable piece of media. The bytes are fetched lazily via `MediaLoader`,
/// because a timeline of a hundred photos should not pull a hundred photos.
public struct Attachment: Sendable, Equatable {
    public let source: MediaSource
    public let filename: String
    public let caption: String?
    public let width: Int?
    public let height: Int?
    public let duration: TimeInterval?
    /// A tiny blurred placeholder the sender computed for us, so the bubble can have
    /// something to show immediately instead of a grey box.
    public let blurhash: String?

    public var aspectRatio: Double? {
        guard let width, let height, height > 0 else { return nil }
        return Double(width) / Double(height)
    }

    public static func == (lhs: Attachment, rhs: Attachment) -> Bool {
        lhs.filename == rhs.filename
            && lhs.caption == rhs.caption
            && lhs.width == rhs.width
            && lhs.height == rhs.height
            && lhs.duration == rhs.duration
            && lhs.blurhash == rhs.blurhash
            && lhs.source.url() == rhs.source.url()
    }
}

/// One message, flattened into something SwiftUI can diff.
public struct Message: Sendable, Identifiable, Equatable {
    public let id: String
    public let kind: MessageKind
    public let senderID: String
    public let senderName: String
    public let senderAvatarURL: String?
    public let isOwn: Bool
    public let timestamp: Date
    public let delivery: DeliveryStatus?
    public let isEdited: Bool
    /// Grouped under one avatar with the message above it, iMessage-style.
    public var isContinuation: Bool = false
}

/// A day separator between messages.
public struct DayDivider: Sendable, Identifiable, Equatable {
    public let id: String
    public let date: Date
}

/// Either a message or the date header above it.
public enum TimelineRow: Sendable, Identifiable, Equatable {
    case message(Message)
    case dayDivider(DayDivider)

    public var id: String {
        switch self {
        case let .message(message): message.id
        case let .dayDivider(divider): divider.id
        }
    }
}
