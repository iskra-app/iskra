import Foundation
import MatrixRustSDK

/// Fetches attachment bytes on demand.
///
/// In an encrypted room the SDK decrypts the file as it downloads, so what comes
/// back here is already plaintext and must be treated as such: it is handed to the
/// view and never written to a cache directory of our own. The SDK's own cache is
/// the encrypted store we set up at sign-in.
/// `Equatable` for one reason, and it is not a tidiness one: this goes into the SwiftUI
/// environment (`\.mediaLoader`), and `IskraRootView` hands it down as `session.media()` —
/// a *fresh value* on every pass through `body`, which is every sync tick. Without a way to
/// compare two of them, SwiftUI must assume the environment changed and invalidate every view
/// that reads it: every avatar, every thumbnail, every voice message, every video note, in the
/// whole tree, several times a second on a busy account.
///
/// Two loaders holding the same `Client` are the same loader. The client is a reference, so
/// identity is the honest comparison — and it is what stops the redraw.
public struct MediaLoader: Sendable, Equatable {
    private let client: Client

    init(client: Client) {
        self.client = client
    }

    public static func == (lhs: MediaLoader, rhs: MediaLoader) -> Bool {
        lhs.client === rhs.client
    }

    /// Full-size media. Use for the photo the user tapped, not for the timeline.
    public func data(for attachment: Attachment) async throws -> Data {
        try await client.getMediaContent(mediaSource: attachment.source)
    }

    /// A thumbnail. Use in the timeline, so that scrolling past a video does not
    /// download the video.
    ///
    /// The sender's own still comes first, and for a video in an encrypted room it is the
    /// only thing that can work — `getMediaThumbnail` asks the *server* to resize the file,
    /// and the server is holding ciphertext it cannot open. That is why every video note was
    /// a grey circle. A photo, whose bytes the SDK can decrypt and resize on the device, is
    /// still thumbnailed the ordinary way when its sender sent no still of their own.
    public func thumbnail(for attachment: Attachment, size: Int) async throws -> Data {
        if let thumbnail = attachment.thumbnailSource {
            return try await client.getMediaContent(mediaSource: thumbnail)
        }

        // A video note whose sender attached no still — including every one this app sent
        // before it learned to attach one, which is a good part of the user's own history.
        // There is nowhere left to get a picture from but the video, so it is fetched and
        // its first frame taken here, on the device. That is a whole clip downloaded for a
        // thumbnail, and it is only ever done for a *note*: square and under a minute, so a
        // few hundred kilobytes. An ordinary video, which can be any size at all, is never
        // pulled down to draw a bubble.
        if attachment.isVideoNote {
            let file = try await file(for: attachment)
            guard let frame = await MediaMetadata.firstFrame(at: file.url) else {
                throw MediaError.noPicture
            }
            return frame
        }

        return try await client.getMediaThumbnail(mediaSource: attachment.source,
                                                  width: UInt64(size),
                                                  height: UInt64(size))
    }

    /// Somebody's face, or a room's picture, from the `mxc://` URL the server hands out
    /// beside their name.
    ///
    /// A thumbnail, always: an avatar is drawn at 28 points and the file behind it may be a
    /// two-megapixel photograph. Unlike the attachments above, this one goes through the
    /// server's own resizer without hesitation — an avatar is public by construction. It
    /// lives outside the room's encryption, which is why the room being encrypted changes
    /// nothing here, and why `thumbnail(for:)` and its careful reasoning about ciphertext do
    /// not apply.
    public func avatar(url: String, size: Int) async throws -> Data {
        let source = try MediaSource.fromUrl(url: url)
        return try await client.getMediaThumbnail(mediaSource: source,
                                                  width: UInt64(size),
                                                  height: UInt64(size))
    }

    /// A file on disk, which is what `AVPlayer` needs to play a video or a voice
    /// message. Hold the `MediaFile` for as long as playback lasts — see its note.
    ///
    /// The mime type is the sender's, and only guessed from the filename when they left
    /// it out: it decides the extension the SDK gives the decrypted file, and an
    /// `AVPlayer` handed a video called `x.bin` refuses to play it.
    public func file(for attachment: Attachment) async throws -> MediaFile {
        let handle = try await client.getMediaFile(mediaSource: attachment.source,
                                                   filename: attachment.filename,
                                                   mimeType: attachment.mimeType
                                                       ?? MediaMetadata.mimeType(ofFilename: attachment.filename)
                                                       ?? "application/octet-stream",
                                                   useCache: true,
                                                   tempDir: nil)
        return try MediaFile(handle: handle)
    }
}

public enum MediaError: Error {
    /// The video is here and no frame could be got out of it.
    case noPicture
}

/// A decrypted attachment sitting on disk, and the promise to take it away again.
///
/// The bytes are plaintext — in an encrypted room the SDK decrypted them on the way down —
/// so the file exists only for as long as this object does: when it deallocates, the SDK
/// deletes it. Whatever is playing the video must therefore hold on to it, and the moment
/// it stops holding it, the user's face leaves the disk.
///
/// It is also what keeps `MediaFileHandle` — an SDK type — from reaching the views, which
/// is the rule `IskraCore` is built around.
public final class MediaFile: Sendable {
    /// Where the bytes are. Feed this to `AVPlayer`.
    public let url: URL

    private let handle: MediaFileHandle

    init(handle: MediaFileHandle) throws {
        self.handle = handle
        url = URL(fileURLWithPath: try handle.path())
    }
}
