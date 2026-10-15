import Foundation
import MatrixRustSDK

/// Turns SDK event content into the one line shown under a room's name.
///
/// Deliberately lossy. Attachments become "Photo", "Voice message" and so on rather
/// than leaking a filename, and anything we cannot render becomes nil rather than a
/// placeholder full of protocol vocabulary.
/// What kind of attachment the last message in a chat is — the small icon the chat list draws in
/// front of "Photo", "Voice message" and the rest. Nil for words.
public enum PreviewKind: Sendable, Equatable {
    case photo, video, videoNote, voice, audio, file, location, sticker, poll
}

/// How far your own last message in a chat has got — the mark in front of it in the chat list.
public enum LastMessageMark: Sendable, Equatable {
    case sending, sent, read, failed
}

enum MessagePreview {
    static func kind(for content: TimelineItemContent) -> PreviewKind? {
        guard case let .msgLike(msgLike) = content else { return nil }
        switch msgLike.kind {
        case let .message(message):
            switch message.msgType {
            case let .image(content):
                return StickerPicture.isSticker(mimeType: content.info?.mimetype, filename: content.filename)
                    ? .sticker : .photo
            case let .video(content):
                return VideoNote.isVideoNote(content) ? .videoNote : .video
            case let .audio(content):
                return content.voice != nil ? .voice : .audio
            case .file: return .file
            case .location: return .location
            default: return nil
            }
        case .sticker: return .sticker
        case .poll: return .poll
        default: return nil
        }
    }

    static func text(for content: TimelineItemContent) -> String? {
        guard case let .msgLike(msgLike) = content else { return nil }

        switch msgLike.kind {
        case let .message(message):
            return text(for: message.msgType)
        case .sticker:
            return String(core: CoreStrings.Preview.sticker)
        case .poll:
            return String(core: CoreStrings.Preview.poll)
        case .redacted:
            return String(core: CoreStrings.Preview.deleted)
        case .unableToDecrypt:
            // Expected, not an error: this device joined after the message was sent
            // and was never given the key. Say so without alarming anyone.
            return String(core: CoreStrings.Preview.unreadable)
        default:
            return nil
        }
    }

    /// The words for one message, whichever door it came in by.
    ///
    /// The room list reads a message off a `TimelineItemContent` and a push reads the same
    /// message off a `MessageLikeEventContent` — two different enums, because one comes from
    /// a timeline the SDK is maintaining and the other from a single event fetched on its
    /// own. Both carry a `MessageType`, and this is where they meet: a photo is "Photo" in
    /// the chat list and "Photo" on the lock screen because it is one sentence, written once.
    static func text(for messageType: MessageType) -> String? {
        switch messageType {
        // The body of a text message is the user's own words, so it is not a string
        // to translate — but it is read off the formatting, not the markup: see `words`.
        case let .text(content):
            return words(content.body, formatted: content.formatted)
        case let .notice(content):
            return words(content.body, formatted: content.formatted)
        case let .emote(content):
            return words(content.body, formatted: content.formatted)
        case let .image(content):
            return String(core: StickerPicture.isSticker(mimeType: content.info?.mimetype, filename: content.filename) ? CoreStrings.Preview.sticker
                                                                                         : CoreStrings.Preview.photo)
        case let .video(content):
            return String(core: VideoNote.isVideoNote(content) ? CoreStrings.Preview.videoNote
                                                               : CoreStrings.Preview.video)
        case let .audio(content):
            // `voice` is the marker that distinguishes a spoken message from a music
            // file; it is what other Matrix clients set, so we read it rather than
            // guessing from the mime type.
            return String(core: content.voice != nil ? CoreStrings.Preview.voice
                                                     : CoreStrings.Preview.audio)
        case .file:
            return String(core: CoreStrings.Preview.file)
        case .location:
            return String(core: CoreStrings.Preview.location)
        default:
            return nil
        }
    }

    /// The words of a formatted message, without the marks that formatted it.
    ///
    /// A message written in Markdown carries it twice: as HTML, and as the Markdown itself in the
    /// plain `body` — which is the fallback for clients that draw no formatting, and which is
    /// exactly what the chat list and the lock screen were drawing: `**важно**`, stars and all. One
    /// line of text cannot be bold, but it can at least not be a lesson in syntax, so where there
    /// is HTML the words are read out of it. (`MatrixHTML` also drops a reply's quoted fallback,
    /// which the plain body drags along from older clients.)
    static func words(_ body: String, formatted: FormattedBody?) -> String {
        guard let formatted, case .html = formatted.format else { return body }
        return words(body, html: formatted.body)
    }

    static func words(_ body: String, html: String?) -> String {
        guard let html, let attributed = MatrixHTML.attributed(html) else { return body }
        return String(attributed.characters)
    }

    /// One message on the screen, in a line — `text(for: MessageKind)`, read off its HTML when it
    /// has some.
    static func text(for message: Message) -> String {
        switch message.kind {
        case let .text(body), let .notice(body), let .emote(body):
            return words(body, html: message.formattedBody)
        default:
            return text(for: message.kind)
        }
    }

    /// The same words again, for a message this app has already flattened.
    ///
    /// The third door into the one sentence, and it is here rather than beside its caller for
    /// exactly the reason the second one is: a photo has to read "Photo" in the chat list, on the
    /// lock screen *and* in the strip above a reply, and three switches over the same vocabulary
    /// is three places for them to drift apart. This one is asked by the quote a reply carries
    /// before the reply has been sent — see `TimelineStore.send` — where all that is left of the
    /// original is the `Message` on the screen.
    static func text(for kind: MessageKind) -> String {
        switch kind {
        case let .text(body), let .notice(body), let .emote(body):
            return body
        case let .image(attachment):
            return attachment.caption ?? String(core: CoreStrings.Preview.photo)
        case .sticker:
            return String(core: CoreStrings.Preview.sticker)
        case .video:
            return String(core: CoreStrings.Preview.video)
        case .videoNote:
            return String(core: CoreStrings.Preview.videoNote)
        case .voice:
            return String(core: CoreStrings.Preview.voice)
        case .audio:
            return String(core: CoreStrings.Preview.audio)
        case .file:
            return String(core: CoreStrings.Preview.file)
        case .location:
            return String(core: CoreStrings.Preview.location)
        case let .poll(poll):
            return poll.question
        case .deleted:
            return String(core: CoreStrings.Preview.deleted)
        case .unreadable:
            return String(core: CoreStrings.Preview.unreadable)
        case .unsupported:
            return ""
        }
    }

    /// Matrix timestamps are milliseconds since the epoch.
    static func date(from timestamp: Timestamp) -> Date {
        Date(timeIntervalSince1970: TimeInterval(timestamp) / 1000)
    }
}
