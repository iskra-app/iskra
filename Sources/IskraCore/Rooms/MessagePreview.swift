import Foundation
import MatrixRustSDK

/// Turns SDK event content into the one line shown under a room's name.
///
/// Deliberately lossy. Attachments become "Photo", "Voice message" and so on rather
/// than leaking a filename, and anything we cannot render becomes nil rather than a
/// placeholder full of protocol vocabulary.
enum MessagePreview {
    static func text(for content: TimelineItemContent) -> String? {
        guard case let .msgLike(msgLike) = content else { return nil }

        switch msgLike.kind {
        case let .message(message):
            return describe(message)
        case .sticker:
            return "Sticker"
        case .poll:
            return "Poll"
        case .redacted:
            return "Message deleted"
        case .unableToDecrypt:
            // Expected, not an error: this device joined after the message was sent
            // and was never given the key. Say so without alarming anyone.
            return "Message you can't read yet"
        default:
            return nil
        }
    }

    private static func describe(_ message: MessageContent) -> String? {
        switch message.msgType {
        case let .text(content):
            return content.body
        case let .notice(content):
            return content.body
        case let .emote(content):
            return content.body
        case .image:
            return "Photo"
        case let .video(content):
            return VideoNote.isVideoNote(content) ? "Video message" : "Video"
        case let .audio(content):
            // `voice` is the marker that distinguishes a spoken message from a music
            // file; it is what other Matrix clients set, so we read it rather than
            // guessing from the mime type.
            return content.voice != nil ? "Voice message" : "Audio"
        case .file:
            return "File"
        case .location:
            return "Location"
        default:
            return nil
        }
    }

    /// Matrix timestamps are milliseconds since the epoch.
    static func date(from timestamp: Timestamp) -> Date {
        Date(timeIntervalSince1970: TimeInterval(timestamp) / 1000)
    }
}
