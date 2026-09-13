import SwiftUI
import IskraCore
import IskraDesign

/// What a piece of media is, once it has been lifted out of the message it arrived in.
///
/// Matrix's own vocabulary is coarser than this — a voice note and a song are both `m.audio`, a
/// round video and a clip from the camera roll are both `m.video` — and the room's tabs are exactly
/// the distinction it does not make. So the split happens here, once, and the five lists downstream
/// each ask for one case instead of each inventing their own test.
enum MediaItemKind: Equatable {
    case photo
    case video
    /// A round video message recorded in the chat. Recognised by shape and length, never by a flag
    /// — see `VideoNote`.
    case videoNote
    case voice
    /// A piece of music or a recording somebody attached, as opposed to one they *spoke*. It lives
    /// in the voice tab too: both are things you press play on, and a tab called "audio" that held
    /// one of them would leave the other homeless.
    case audio
    case file
}

/// One piece of media in a room, flattened out of the message it arrived in so that a grid or a
/// list can lay them out without the conversation around them.
struct MediaItem: Identifiable, Equatable {
    let id: String
    let attachment: Attachment
    let kind: MediaItemKind
    let sender: String
    let timestamp: Date

    /// Whether the viewer should play it rather than show it — the one thing `MediaViewer` and the
    /// grid's corner badge both need to know.
    var isVideo: Bool { kind == .video || kind == .videoNote }

    /// Pulls the media out of a run of messages, newest first as the timeline holds them. Text,
    /// locations, stickers and the rest are not attachments anybody goes looking for later, so they
    /// fall away.
    static func items(from messages: [Message]) -> [MediaItem] {
        messages.compactMap { message in
            switch message.kind {
            case let .image(attachment):
                item(message, attachment, kind: .photo)
            case let .video(attachment):
                // The SDK says "video" for both; only the shape says which.
                item(message, attachment, kind: attachment.isVideoNote ? .videoNote : .video)
            case let .videoNote(attachment):
                item(message, attachment, kind: .videoNote)
            case let .voice(attachment, _):
                item(message, attachment, kind: .voice)
            case let .audio(attachment):
                item(message, attachment, kind: .audio)
            case let .file(attachment):
                item(message, attachment, kind: .file)
            default:
                nil
            }
        }
    }

    private static func item(_ message: Message, _ attachment: Attachment, kind: MediaItemKind) -> MediaItem {
        MediaItem(id: message.id, attachment: attachment, kind: kind,
                  sender: message.senderName, timestamp: message.timestamp)
    }
}

/// A sheet needs an `Identifiable` item, and a bare index is not one — two opens at the same index
/// would be "the same" and the second would not present. This wraps it.
struct OpenedIndex: Identifiable {
    let value: Int
    var id: Int { value }
}

/// The full-screen viewer, swipeable across a room's pictures and videos — Telegram's horizontal
/// paging. Each page is the same `MediaViewer` a single tap opens, so zoom, share, save and
/// drag-to-dismiss all come along; the page swipe is the one thing added on top.
struct MediaPager: View {
    let items: [MediaItem]
    @State var index: Int

    init(items: [MediaItem], startIndex: Int) {
        self.items = items
        _index = State(initialValue: startIndex)
    }

    var body: some View {
        TabView(selection: $index) {
            ForEach(Array(items.enumerated()), id: \.element.id) { offset, item in
                MediaViewer(attachment: item.attachment,
                            isVideo: item.isVideo,
                            sender: item.sender,
                            timestamp: item.timestamp)
                    .tag(offset)
            }
        }
        #if os(iOS)
        .tabViewStyle(.page(indexDisplayMode: .never))
        #endif
    }
}
