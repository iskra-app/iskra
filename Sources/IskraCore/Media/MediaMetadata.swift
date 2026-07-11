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
    }

    struct Video {
        let width: UInt64?
        let height: UInt64?
        let duration: TimeInterval?
        let mimeType: String
        let size: UInt64
        /// JPEG bytes, sent alongside so a receiver has something to show at once.
        let thumbnail: Data?
    }

    // MARK: - Reading

    static func image(at url: URL) -> Image {
        var width: UInt64?
        var height: UInt64?

        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.uint64Value
            height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.uint64Value
        }

        return Image(width: width,
                     height: height,
                     mimeType: mimeType(of: url) ?? "image/jpeg",
                     size: fileSize(of: url))
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

        return Video(width: width,
                     height: height,
                     duration: duration,
                     mimeType: mimeType(of: url) ?? "video/mp4",
                     size: fileSize(of: url),
                     thumbnail: await thumbnail(for: asset))
    }

    static func file(at url: URL) -> FileInfo {
        FileInfo(mimetype: mimeType(of: url) ?? "application/octet-stream",
                 size: fileSize(of: url),
                 thumbnailInfo: nil,
                 thumbnailSource: nil)
    }

    // MARK: - Helpers

    private static func thumbnail(for asset: AVURLAsset) async -> Data? {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 800, height: 800)

        guard let image = try? await generator.image(at: .zero).image else { return nil }

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

    static func fileSize(of url: URL) -> UInt64 {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { UInt64($0) } ?? 0
    }
}
