import Foundation
import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import MatrixRustSDK

/// Reads the facts about a file that a Matrix event has to carry.
///
/// This matters more than it looks. Width, height and duration travel in the event
/// *outside* the encrypted attachment, and they are what lets a receiving client lay
/// out the bubble before the file has downloaded. Send them wrong and every other
/// client shows a grey box of the wrong shape; omit the duration on a video and it
/// cannot be told from a photo.
enum MediaMetadata {
    struct Image {
        let width: UInt64?
        let height: UInt64?
        let mimeType: String
        let size: UInt64
        /// Never nil, and the SDK will not send a picture without it — see `Blurhash`.
        let blurhash: String
    }

    struct Video {
        let width: UInt64?
        let height: UInt64?
        let duration: TimeInterval?
        let mimeType: String
        let size: UInt64
        /// The still, sent alongside so a receiver has something to show at once.
        let thumbnail: Thumbnail?
        /// Taken from the first frame, and required for the same reason a photo's is.
        let blurhash: String
        /// Whether the clip has any sound on it at all. Nothing in the event carries this —
        /// it is here so that a silent video note can be *noticed*, on the side that made
        /// it, instead of being discovered by whoever it was sent to.
        let hasAudio: Bool
    }

    /// A video's first frame, ready to upload.
    ///
    /// The size travels with the bytes because the SDK will not send a thumbnail without
    /// it: `sendVideo` takes the picture and its `ThumbnailInfo` as a pair, and given only
    /// one of the two it quietly attaches neither. That is how every video note went out
    /// with no still on it, and every circle in the timeline came back grey.
    struct Thumbnail {
        let data: Data
        let width: UInt64
        let height: UInt64
        let mimeType = "image/jpeg"

        var size: UInt64 { UInt64(data.count) }
    }

    // MARK: - Reading

    /// Read straight from the bytes, because that is what a picked photo *is* — there is no
    /// file, and inventing one only to ask its size back would be asking the disk a question
    /// we are holding the answer to.
    static func image(data: Data, filename: String) -> Image {
        var width: UInt64?
        var height: UInt64?

        if let source = CGImageSourceCreateWithData(data as CFData, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.uint64Value
            height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.uint64Value
        }

        return Image(width: width,
                     height: height,
                     mimeType: mimeType(ofFilename: filename) ?? "image/jpeg",
                     size: UInt64(data.count),
                     blurhash: Blurhash.encode(imageData: data))
    }

    static func video(at url: URL) async -> Video {
        let asset = AVURLAsset(url: url)

        var width: UInt64?
        var height: UInt64?
        var duration: TimeInterval?

        if let track = try? await asset.loadTracks(withMediaType: .video).first {
            // `naturalSize` ignores the rotation a phone camera records, so a portrait
            // clip would claim to be landscape. Applying the transform is what makes a
            // video note actually square in the receiver's eyes.
            let size = try? await track.load(.naturalSize)
            let transform = try? await track.load(.preferredTransform)
            if let size, let transform {
                let oriented = size.applying(transform)
                width = UInt64(abs(oriented.width))
                height = UInt64(abs(oriented.height))
            }
        }

        if let cmDuration = try? await asset.load(.duration) {
            duration = CMTimeGetSeconds(cmDuration)
        }

        // The first frame serves twice: as the picture a receiver sees before the video
        // downloads, and as the image the blurhash is taken from.
        let frame = await firstFrame(of: asset)

        let hasAudio = ((try? await asset.loadTracks(withMediaType: .audio)) ?? []).isEmpty == false

        return Video(width: width,
                     height: height,
                     duration: duration,
                     mimeType: mimeType(of: url) ?? "video/mp4",
                     size: fileSize(of: url),
                     thumbnail: frame.flatMap(thumbnail(from:)),
                     blurhash: frame.map(Blurhash.encode) ?? Blurhash.neutral,
                     hasAudio: hasAudio)
    }

    static func file(at url: URL) -> FileInfo {
        FileInfo(mimetype: mimeType(of: url) ?? "application/octet-stream",
                 size: fileSize(of: url),
                 thumbnailInfo: nil,
                 thumbnailSource: nil)
    }

    /// The first frame of a video already on disk, as a JPEG.
    ///
    /// For a clip whose sender attached no still of their own — including every video note
    /// this app sent before it learned to attach one. See `MediaLoader.thumbnail`.
    static func firstFrame(at url: URL) async -> Data? {
        guard let frame = await firstFrame(of: AVURLAsset(url: url)) else { return nil }
        return jpeg(from: frame)
    }

    // MARK: - Helpers

    private static func thumbnail(from image: CGImage) -> Thumbnail? {
        guard let data = jpeg(from: image) else { return nil }
        return Thumbnail(data: data, width: UInt64(image.width), height: UInt64(image.height))
    }

    private static func firstFrame(of asset: AVURLAsset) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 800, height: 800)

        return try? await generator.image(at: .zero).image
    }

    private static func jpeg(from image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }

        return data as Data
    }

    static func mimeType(of url: URL) -> String? {
        UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
    }

    static func mimeType(ofFilename filename: String) -> String? {
        UTType(filenameExtension: (filename as NSString).pathExtension)?.preferredMIMEType
    }

    static func fileSize(of url: URL) -> UInt64 {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { UInt64($0) } ?? 0
    }
}
