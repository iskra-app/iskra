import Foundation
import MatrixRustSDK

/// Fetches attachment bytes on demand.
///
/// In an encrypted room the SDK decrypts the file as it downloads, so what comes
/// back here is already plaintext and must be treated as such: it is handed to the
/// view and never written to a cache directory of our own. The SDK's own cache is
/// the encrypted store we set up at sign-in.
public struct MediaLoader: Sendable {
    private let client: Client

    init(client: Client) {
        self.client = client
    }

    /// Full-size media. Use for the photo the user tapped, not for the timeline.
    public func data(for attachment: Attachment) async throws -> Data {
        try await client.getMediaContent(mediaSource: attachment.source)
    }

    /// A thumbnail. Use in the timeline, so that scrolling past a video does not
    /// download the video.
    public func thumbnail(for attachment: Attachment, size: Int) async throws -> Data {
        try await client.getMediaThumbnail(mediaSource: attachment.source,
                                           width: UInt64(size),
                                           height: UInt64(size))
    }

    /// A file on disk, which is what `AVPlayer` needs to play a video or a voice
    /// message. The handle keeps the file alive; when it deallocates, the SDK
    /// removes the file. Hold it for as long as playback lasts.
    public func file(for attachment: Attachment, mimeType: String) async throws -> MediaFileHandle {
        try await client.getMediaFile(mediaSource: attachment.source,
                                      filename: attachment.filename,
                                      mimeType: mimeType,
                                      useCache: true,
                                      tempDir: nil)
    }
}
