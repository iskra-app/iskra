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

    /// Whether the viewer should play it rather than show it — the one thing the gallery and the
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

/// Everything in this room worth opening full-screen, asked for at the moment somebody opens one.
///
/// A photograph tapped in a conversation used to open alone: one picture, one viewer, and the only
/// way to the next one was to close it, scroll, and tap again — while the room's media *tab*, which
/// nobody opens as often, had the swipe between them all along. The difference was never a decision;
/// it was that a row knows about its own message and nothing else.
///
/// So the room hands the list down, and hands it down as a *closure*. Not as an array: the array is
/// rebuilt out of every message the timeline holds, and an array in the environment would be
/// recomputed and re-diffed on every change to a conversation that is already changing constantly —
/// a photo arriving, a receipt landing, somebody typing. Asked for on a tap, it is computed once,
/// for the one thing it is for.
///
/// A reference type so that its identity is stable: a fresh closure in the environment on every
/// pass of the room's body would invalidate every row in the conversation.
@MainActor
final class RoomMediaSource {
    private let provider: () -> [MediaItem]

    init(provider: @escaping () -> [MediaItem]) {
        self.provider = provider
    }

    /// The pictures and the videos, newest first as the timeline holds them.
    ///
    /// Only those two. Files, music and voice notes are media as far as the room's tabs are
    /// concerned, and they are not things a full-screen viewer can show — a swipe that landed on a
    /// PDF would be a black screen with a name on it.
    func viewable() -> [MediaItem] {
        provider().filter { $0.kind == .photo || $0.kind == .video }
    }
}

extension EnvironmentValues {
    /// The room's pictures, for the viewer a message opens. Absent outside a conversation — in the
    /// media grid, which has its own list, and in search results, where a photograph is on its own.
    @Entry var roomMedia: RoomMediaSource?

    /// Told when something inside the room covers the whole of it — the photo viewer, on a
    /// phone — and when it stops. The room goes on existing underneath; see `RoomView.onDisappear`,
    /// which used to take the cover for the reader leaving and shut the room down behind it.
    @Entry var coversRoom: @MainActor (Bool) -> Void = { _ in }
}
