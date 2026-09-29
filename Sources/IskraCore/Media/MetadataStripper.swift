import Foundation
import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Takes out of a photo or a video everything that is not the picture.
///
/// A photo off a phone carries where it was taken to a few metres, when to the second, the make,
/// model and lens of the camera, often its serial number, and whatever the editing app wrote about
/// itself; a video carries the same in its own boxes. Attachment encryption hides all of it from
/// the server and none of it from the people in the room — and in a group, "the people in the room"
/// can be anyone with the link. Somebody sending a photo of their cat is not deciding to send their
/// home address with it, so the address stays behind.
///
/// Kept: the pixels, the colour profile, the orientation (without it a portrait photo arrives on its
/// side), and for an animation its timing. Nothing else.
///
/// **What is sent is what was checked, never what was hoped.** The two ways ImageIO offers to drop
/// metadata do not agree about what "drop" means: copying a JPEG without its metadata comes out
/// clean, while the same call on a HEIC keeps the capture date, the IPTC city and the software, and
/// on a PNG keeps the GPS outright. So every result is read back and held to `isClean`, and if the
/// cheap way left anything behind the picture is drawn again from its pixels. If even that is not
/// clean the photo is not sent — a send that fails where the user can see it, and never a picture
/// that goes out with the one thing they were told it would not carry.
enum MetadataStripper {
    /// The name it came with, unless the format had to change — a WebP, which ImageIO can read and
    /// cannot write, goes as a PNG and is named as one.
    typealias Photo = PhotoFile

    // MARK: - Photos

    /// The photo with nothing in it but itself, or nil if that could not be made.
    static func photo(_ data: Data, filename: String) -> Photo? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source) as String?,
              CGImageSourceGetCount(source) > 0 else { return nil }

        let writable = (CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []).contains(type)

        // Without re-encoding first: a JPEG comes through this bit for bit, which is most photos
        // anybody sends from anything but an iPhone.
        if writable, let copied = copy(source, as: type), isClean(photo: copied) {
            return Photo(data: copied, filename: filename)
        }

        let target = writable ? type : UTType.png.identifier
        guard let redrawn = redraw(source, as: target), isClean(photo: redrawn) else { return nil }
        return Photo(data: redrawn, filename: target == type ? filename : renamed(filename, as: target))
    }

    /// Whether every frame of this image carries nothing but what describes the picture itself.
    ///
    /// An allow-list, not a deny-list: the question is not "is the GPS gone" but "is anything left
    /// that we did not decide to keep", and a list of what to forbid is only ever as long as the
    /// list of things its author thought of. What is allowed here is exactly what ImageIO writes on
    /// its own into an image made from pixels alone.
    static func isClean(photo data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return false }

        for index in 0..<count {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any]
            else { return false }
            for (key, value) in properties where key.hasPrefix("{") {
                guard let allowed = allowedProperties[key] else { return false }
                guard let allowed else { continue }
                guard let dictionary = value as? [String: Any] else { return false }
                if !Set(dictionary.keys).isSubset(of: allowed) { return false }
            }

            // XMP gets its own look, because a packet of it can carry what no property dictionary
            // mentions: ImageIO reports it here, and only here.
            if let metadata = CGImageSourceCopyMetadataAtIndex(source, index, nil),
               let tags = CGImageMetadataCopyTags(metadata) as? [CGImageMetadataTag] {
                for tag in tags {
                    guard let prefix = CGImageMetadataTagCopyPrefix(tag) as String?,
                          let name = CGImageMetadataTagCopyName(tag) as String?,
                          allowedXMP.contains("\(prefix):\(name)") else { return false }
                }
            }
        }
        return true
    }

    /// Per property dictionary, the keys that may stay — `nil` meaning all of them. Anything not
    /// named here at all is not allowed: `{GPS}`, `{IPTC}`, `{ExifAux}`, every `{Maker…}`, and
    /// whatever a later ImageIO learns to read.
    ///
    /// `{JFIF}` is the JPEG's own header — a version and a pixel density, and nothing that is
    /// anybody's. `{Exif}` keeps only the three facts ImageIO writes into every JPEG it makes;
    /// `{TIFF}` keeps the orientation and the tiling HEIC is stored in.
    private static let allowedProperties: [String: Set<String>?] = [
        kCGImagePropertyJFIFDictionary as String: nil,
        kCGImagePropertyExifDictionary as String: [
            kCGImagePropertyExifPixelXDimension, kCGImagePropertyExifPixelYDimension,
            kCGImagePropertyExifColorSpace,
        ].strings,
        kCGImagePropertyTIFFDictionary as String: [
            kCGImagePropertyTIFFOrientation, kCGImagePropertyTIFFTileWidth, kCGImagePropertyTIFFTileLength,
            kCGImagePropertyTIFFXResolution, kCGImagePropertyTIFFYResolution, kCGImagePropertyTIFFResolutionUnit,
        ].strings,
        kCGImagePropertyPNGDictionary as String: [
            kCGImagePropertyPNGInterlaceType, kCGImagePropertyPNGGamma, kCGImagePropertyPNGChromaticities,
            kCGImagePropertyPNGsRGBIntent, kCGImagePropertyPNGXPixelsPerMeter, kCGImagePropertyPNGYPixelsPerMeter,
            kCGImagePropertyAPNGLoopCount, kCGImagePropertyAPNGDelayTime, kCGImagePropertyAPNGUnclampedDelayTime,
            kCGImagePropertyAPNGFrameInfoArray, kCGImagePropertyAPNGCanvasPixelWidth,
            kCGImagePropertyAPNGCanvasPixelHeight,
        ].strings,
        kCGImagePropertyGIFDictionary as String: [
            kCGImagePropertyGIFLoopCount, kCGImagePropertyGIFDelayTime, kCGImagePropertyGIFUnclampedDelayTime,
            kCGImagePropertyGIFHasGlobalColorMap, kCGImagePropertyGIFImageColorMap,
            kCGImagePropertyGIFFrameInfoArray, kCGImagePropertyGIFCanvasPixelWidth,
            kCGImagePropertyGIFCanvasPixelHeight,
        ].strings,
        kCGImagePropertyHEICSDictionary as String: [
            kCGImagePropertyHEICSLoopCount, kCGImagePropertyHEICSDelayTime,
            kCGImagePropertyHEICSUnclampedDelayTime, kCGImagePropertyHEICSFrameInfoArray,
            kCGImagePropertyHEICSCanvasPixelWidth, kCGImagePropertyHEICSCanvasPixelHeight,
        ].strings,
    ]

    /// The same facts, as ImageIO mirrors them into XMP.
    private static let allowedXMP: Set<String> = [
        "tiff:Orientation", "tiff:TileWidth", "tiff:TileLength",
        "tiff:XResolution", "tiff:YResolution", "tiff:ResolutionUnit",
        "exif:PixelXDimension", "exif:PixelYDimension", "exif:ColorSpace",
    ]

    /// The compressed image as it is, with an empty set of metadata in place of its own — except
    /// the orientation, which is part of how the picture looks and not a fact about who took it.
    private static func copy(_ source: CGImageSource, as type: String) -> Data? {
        let output = NSMutableData()
        let count = CGImageSourceGetCount(source)
        guard let destination = CGImageDestinationCreateWithData(output, type as CFString, count, nil)
        else { return nil }

        let metadata = CGImageMetadataCreateMutable()
        CGImageMetadataSetValueMatchingImageProperty(metadata,
                                                     kCGImagePropertyTIFFDictionary,
                                                     kCGImagePropertyTIFFOrientation,
                                                     orientation(of: source, at: 0) as CFNumber)
        let options: [CFString: Any] = [
            kCGImageDestinationMetadata: metadata,
            kCGImageDestinationMergeMetadata: false,
            kCGImageMetadataShouldExcludeGPS: true,
            kCGImageMetadataShouldExcludeXMP: true,
        ]
        guard CGImageDestinationCopyImageSource(destination, source, options as CFDictionary, nil) else {
            return nil
        }
        return output as Data
    }

    /// Every frame drawn again from its pixels, carrying its orientation and its timing and
    /// nothing else. The colour profile travels inside the decoded image, so it survives this too.
    private static func redraw(_ source: CGImageSource, as type: String) -> Data? {
        let output = NSMutableData()
        let count = CGImageSourceGetCount(source)
        guard let destination = CGImageDestinationCreateWithData(output, type as CFString, count, nil)
        else { return nil }

        if let container = CGImageSourceCopyProperties(source, nil) as? [String: Any] {
            CGImageDestinationSetProperties(destination, timing(in: container, keeping: loopKeys) as CFDictionary)
        }

        for index in 0..<count {
            guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else { return nil }
            var properties: [String: Any] = [
                kCGImagePropertyOrientation as String: orientation(of: source, at: index),
                kCGImageDestinationLossyCompressionQuality as String: redrawQuality,
            ]
            if let frame = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any] {
                properties.merge(timing(in: frame, keeping: delayKeys)) { current, _ in current }
            }
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    /// High, because a photo drawn again is a photo compressed twice, and the second time should
    /// not be the one anybody notices.
    private static let redrawQuality = 0.92

    /// The dictionaries an animation keeps its timing in, and the keys of it worth carrying.
    private static let animationDictionaries = [
        kCGImagePropertyGIFDictionary, kCGImagePropertyPNGDictionary, kCGImagePropertyHEICSDictionary,
    ].strings
    private static let loopKeys: Set<String> = [
        kCGImagePropertyGIFLoopCount, kCGImagePropertyAPNGLoopCount, kCGImagePropertyHEICSLoopCount,
    ].strings
    private static let delayKeys: Set<String> = [
        kCGImagePropertyGIFDelayTime, kCGImagePropertyGIFUnclampedDelayTime,
        kCGImagePropertyAPNGDelayTime, kCGImagePropertyAPNGUnclampedDelayTime,
        kCGImagePropertyHEICSDelayTime, kCGImagePropertyHEICSUnclampedDelayTime,
    ].strings

    private static func timing(in properties: [String: Any], keeping keys: Set<String>) -> [String: Any] {
        var kept: [String: Any] = [:]
        for name in animationDictionaries {
            guard let dictionary = properties[name] as? [String: Any] else { continue }
            let timing = dictionary.filter { keys.contains($0.key) }
            if !timing.isEmpty { kept[name] = timing }
        }
        return kept
    }

    private static func orientation(of source: CGImageSource, at index: Int) -> Int {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any]
        return (properties?[kCGImagePropertyOrientation as String] as? NSNumber)?.intValue ?? 1
    }

    private static func renamed(_ filename: String, as type: String) -> String {
        let stem = (filename as NSString).deletingPathExtension
        let suffix = UTType(type)?.preferredFilenameExtension ?? "png"
        return "\(stem.isEmpty ? UUID().uuidString : stem).\(suffix)"
    }


    // MARK: - Videos

    /// A copy of the video with only its pictures and its sound in it, moved rather than
    /// re-encoded — see `VideoExport`. A video that is compressed as well is stripped in the same
    /// pass instead, by `VideoTranscoder`, and never written out twice.
    static func video(at url: URL) async throws -> URL {
        try await VideoExport.stripped(url)
    }

    /// Whether the file carries nothing but pictures and sound: no metadata on the movie, none on
    /// any track, and no track of any other kind.
    static func isClean(video url: URL) async throws -> Bool {
        let asset = AVURLAsset(url: url)
        for format in try await asset.load(.availableMetadataFormats) {
            if try await !asset.loadMetadata(for: format).isEmpty { return false }
        }
        for track in try await asset.load(.tracks) {
            guard track.mediaType == .video || track.mediaType == .audio else { return false }
            for format in try await track.load(.availableMetadataFormats) {
                if try await !track.loadMetadata(for: format).isEmpty { return false }
            }
        }
        return true
    }

    /// Removes a copy `video(at:)` made, and the folder it was made in.
    static func discard(_ url: URL) {
        VideoExport.discard(url)
    }
}

private extension Array where Element == CFString {
    var strings: Set<String> { Set(map { $0 as String }) }
}
