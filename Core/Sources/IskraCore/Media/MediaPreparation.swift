import Foundation
import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// A photo on its way out: the bytes that will be sent, and the name they will be sent under.
struct PhotoFile: Sendable, Equatable {
    let data: Data
    let filename: String
}

/// What a photo or a video is turned into before it is sent — compressed, stripped, both or
/// neither — according to `MediaSettings`.
///
/// Compression first, then stripping, and the order is not arbitrary: compressing draws the
/// picture again from its pixels, so the stripper that runs after it is handed a file with
/// nothing in it and passes it through without touching the pixels a second time. And the
/// stripper is always the *last* thing to touch the file, so its check — the read-back that
/// refuses anything not clean — is a check on exactly what is sent.
enum MediaPreparation {
    /// The photo to send, or nil if the settings ask for it to be stripped and that could not be
    /// done — which is a refusal, never a fallback to the original.
    ///
    /// With compression on, the smaller of two wins: the compressed photo, and the original (stripped,
    /// if it is to be). Usually that is plainly the compressed one and the original is not even
    /// looked at. But a HEIC is already small, and a JPEG of the same picture can come out bigger —
    /// and stripping a HEIC redraws it, which can make *it* bigger too: a 455 KB photo went out at
    /// 740 KB with "compress" switched on. Sending the bigger of two clean files is never the answer.
    static func photo(_ data: Data, filename: String, settings: MediaSettings) -> PhotoFile? {
        let original = PhotoFile(data: data, filename: filename)
        let finish = { (photo: PhotoFile) -> PhotoFile? in
            settings.stripsMetadata ? MetadataStripper.photo(photo.data, filename: photo.filename) : photo
        }

        guard settings.compresses,
              let compressed = MediaCompressor.photo(data, filename: filename, level: settings.compression,
                                                     keepingMetadata: !settings.stripsMetadata)
        else { return finish(original) }

        if compressed.data.count < data.count { return finish(compressed) }
        return [compressed, original].compactMap(finish).min { $0.data.count < $1.data.count }
    }

    /// A video ready to send, and whether it is a copy of ours to take away afterwards.
    struct Video: Sendable {
        let url: URL
        let isCopy: Bool

        /// Removes the copy, if there is one. The original is the caller's and is never touched.
        func discard() {
            if isCopy { VideoExport.discard(url) }
        }
    }

    /// The video to send.
    ///
    /// A compression that fails, or that comes out *larger* than what it started from — a clip
    /// already small, or already squeezed by whoever sent it first — is not a reason to refuse
    /// the video: it goes at its own size. Stripping that fails is, as it is for a photo.
    static func video(_ url: URL, settings: MediaSettings) async throws -> Video {
        if settings.compresses {
            do {
                // Bounded, generously: a phone re-encodes far faster than real time, so three times
                // the clip's length is only ever reached by something stuck — and then the video
                // goes uncompressed rather than never.
                let length = try await AVURLAsset(url: url).load(.duration).seconds
                let limit = Duration.seconds(30 + 3 * (length.isFinite ? length : 0))
                let level = settings.compression, strips = settings.stripsMetadata
                let smaller = try await withTimeout(limit) {
                    try await VideoTranscoder.transcode(url, level: level, stripsMetadata: strips)
                }
                if MediaMetadata.fileSize(of: smaller) < MediaMetadata.fileSize(of: url) {
                    return Video(url: smaller, isCopy: true)
                }
                VideoExport.discard(smaller)
            } catch {
                Log.media.error("video sent uncompressed: \(Log.describe(error), privacy: .public)")
            }
        }
        guard settings.stripsMetadata else { return Video(url: url, isCopy: false) }
        return Video(url: try await MetadataStripper.video(at: url), isCopy: true)
    }
}

/// Makes a photo smaller: no longer than its step allows on its longest side, and compressed as
/// a JPEG.
enum MediaCompressor {
    /// The compressed photo, or nil when there is nothing to compress — an animation (which would
    /// come out as its first frame) or a picture that will not decode. Nil means "send what you
    /// have", never "do not send". Whether it came out any *smaller* is the caller's to weigh —
    /// see `MediaPreparation.photo`.
    ///
    /// A picture with transparency stays a PNG, because a JPEG would fill the transparent part
    /// with black; everything else becomes a JPEG, which besides being small is the one format
    /// every client on the other end can draw. HEIC is not.
    ///
    /// The orientation is applied to the pixels rather than carried as a flag, so the result is
    /// the right way up in any viewer, including the ones that ignore the flag. With
    /// `keepingMetadata` the rest of what the original said about itself — the location, the
    /// camera, the dates — is written into the new file; without it, the new file carries only
    /// the picture.
    static func photo(_ data: Data, filename: String, level: MediaCompression,
                      keepingMetadata: Bool) -> PhotoFile? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
        else { return nil }

        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: level.maxPhotoSide,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary) else { return nil }
        let type: UTType = isTransparent(image) ? .png : .jpeg

        var options: [String: Any] = [kCGImageDestinationLossyCompressionQuality as String: level.photoQuality]
        if keepingMetadata {
            options.merge(describing(properties)) { current, _ in current }
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }

        let stem = (filename as NSString).deletingPathExtension
        return PhotoFile(data: output as Data,
                         filename: "\(stem.isEmpty ? UUID().uuidString : stem).\(type.preferredFilenameExtension ?? "jpg")")
    }

    /// Whether any pixel is actually see-through — not whether the file has room for it to be.
    ///
    /// The flag is not the answer: a Mac screenshot and half the pictures an app exports carry an
    /// alpha channel that is opaque from edge to edge, and taking the flag at its word kept a 4.5 MB
    /// screenshot a 4.5 MB PNG with compression on. So the alpha is drawn out on its own, one byte
    /// a pixel, and looked at.
    private static func isTransparent(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: break
        }
        let width = image.width, height = image.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue),
              let pixels = context.data else { return true }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let alpha = UnsafeBufferPointer(start: pixels.assumingMemoryBound(to: UInt8.self),
                                        count: context.bytesPerRow * height)
        return alpha.contains { $0 < .max }
    }

    /// The original's own description of itself, minus the facts that stopped being true when it
    /// was redrawn: its size, and its orientation — which is now in the pixels.
    private static func describing(_ properties: [String: Any]) -> [String: Any] {
        var kept: [String: Any] = [:]
        let stale: Set<String> = [
            kCGImagePropertyTIFFOrientation as String,
            kCGImagePropertyExifPixelXDimension as String, kCGImagePropertyExifPixelYDimension as String,
        ]
        for name in [kCGImagePropertyGPSDictionary, kCGImagePropertyExifDictionary,
                     kCGImagePropertyTIFFDictionary, kCGImagePropertyIPTCDictionary] {
            guard let dictionary = properties[name as String] as? [String: Any] else { continue }
            kept[name as String] = dictionary.filter { !stale.contains($0.key) }
        }
        return kept
    }
}
