import Testing
import Foundation
import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import IskraCore

/// What leaves the phone with a photo or a video: the picture, and nothing about who took it where.
///
/// Every fixture here is written the way a phone writes one — a location, a camera, a serial
/// number, a capture date, a name — and each test asks two things of the result: that none of it
/// is left, and that the picture is still the picture (the same size, the same way up, the same
/// colours, and for an animation the same frames at the same pace). The second half matters as
/// much as the first: stripping that loses the orientation sends every portrait photo sideways.
@Suite
struct MetadataStripperTests {
    // MARK: - Photos

    @Test("a photo loses where, when and on what it was taken", arguments: [UTType.jpeg, .heic, .png])
    func photoIsStripped(type: UTType) throws {
        let original = try Fixture.photo(type)
        #expect(!MetadataStripper.isClean(photo: original), "the fixture must carry metadata to begin with")

        let stripped = try #require(MetadataStripper.photo(original, filename: "IMG_0042.\(type.preferredFilenameExtension!)"))
        #expect(MetadataStripper.isClean(photo: stripped.data))

        let properties = try Fixture.properties(of: stripped.data)
        for dictionary in [kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary,
                           kCGImagePropertyMakerAppleDictionary] {
            #expect(properties[dictionary as String] == nil)
        }
        let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        #expect(tiff[kCGImagePropertyTIFFModel as String] == nil)
        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        #expect(exif[kCGImagePropertyExifDateTimeOriginal as String] == nil)
        #expect(exif[kCGImagePropertyExifBodySerialNumber as String] == nil)

        // And nowhere in the bytes either — not in some block ImageIO does not report.
        for secret in Fixture.secrets {
            #expect(stripped.data.range(of: Data(secret.utf8)) == nil, "\(secret) is still in the file")
        }
    }

    @Test("the picture itself survives: size, orientation, colour profile, name",
          arguments: [UTType.jpeg, .heic, .png])
    func pictureSurvives(type: UTType) throws {
        let name = "IMG_0042.\(type.preferredFilenameExtension!)"
        let stripped = try #require(MetadataStripper.photo(try Fixture.photo(type), filename: name))
        let properties = try Fixture.properties(of: stripped.data)

        #expect(properties[kCGImagePropertyPixelWidth as String] as? Int == Fixture.width)
        #expect(properties[kCGImagePropertyPixelHeight as String] as? Int == Fixture.height)
        #expect(properties[kCGImagePropertyOrientation as String] as? Int == Fixture.orientation)
        #expect(properties[kCGImagePropertyProfileName as String] as? String == "Display P3")
        #expect(stripped.filename == name)
        #expect(Fixture.type(of: stripped.data) == type)
    }

    @Test("a JPEG goes without being compressed again")
    func jpegIsNotRecompressed() throws {
        let original = try Fixture.photo(.jpeg)
        let stripped = try #require(MetadataStripper.photo(original, filename: "a.jpg"))
        let pixels = { (data: Data) -> Data? in
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
            return image.dataProvider?.data as Data?
        }
        #expect(pixels(stripped.data) == pixels(original))
    }

    @Test("an animation keeps every frame and its timing")
    func animationSurvives() throws {
        let original = try Fixture.animatedGIF()
        #expect(!MetadataStripper.isClean(photo: original))

        let stripped = try #require(MetadataStripper.photo(original, filename: "cat.gif"))
        #expect(MetadataStripper.isClean(photo: stripped.data))

        let source = try #require(CGImageSourceCreateWithData(stripped.data as CFData, nil))
        #expect(CGImageSourceGetCount(source) == Fixture.frames)
        let frame = CGImageSourceCopyPropertiesAtIndex(source, 1, nil) as? [String: Any]
        let gif = frame?[kCGImagePropertyGIFDictionary as String] as? [String: Any]
        #expect((gif?[kCGImagePropertyGIFDelayTime as String] as? Double).map { abs($0 - Fixture.delay) < 0.01 } == true)
    }

    @Test("a photo that is already clean goes as it is")
    func cleanPhotoIsAccepted() throws {
        let clean = try Fixture.photo(.png, tagged: false)
        #expect(MetadataStripper.isClean(photo: clean))
        #expect(MetadataStripper.photo(clean, filename: "a.png") != nil)
    }

    @Test("bytes that are not a picture are refused, not sent as they are")
    func garbageIsRefused() {
        #expect(MetadataStripper.photo(Data("not an image".utf8), filename: "a.jpg") == nil)
    }

    // MARK: - Videos

    @Test("a video loses its location, camera, dates and author", arguments: [AVFileType.mov, .mp4])
    func videoIsStripped(type: AVFileType) async throws {
        let original = try await Fixture.video(type)
        defer { try? FileManager.default.removeItem(at: original) }
        #expect(try await !MetadataStripper.isClean(video: original), "the fixture must carry metadata to begin with")

        let stripped = try await MetadataStripper.video(at: original)
        defer { MetadataStripper.discard(stripped) }
        #expect(try await MetadataStripper.isClean(video: stripped))

        let bytes = try Data(contentsOf: stripped)
        for secret in Fixture.secrets {
            #expect(bytes.range(of: Data(secret.utf8)) == nil, "\(secret) is still in the file")
        }
    }

    @Test("the video itself survives: its name, its container, its rotation, its length",
          arguments: [AVFileType.mov, .mp4])
    func videoSurvives(type: AVFileType) async throws {
        let original = try await Fixture.video(type)
        defer { try? FileManager.default.removeItem(at: original) }

        let stripped = try await MetadataStripper.video(at: original)
        defer { MetadataStripper.discard(stripped) }

        #expect(stripped.lastPathComponent == original.lastPathComponent)
        #expect(stripped.deletingLastPathComponent() != original.deletingLastPathComponent())

        let before = AVURLAsset(url: original), after = AVURLAsset(url: stripped)
        let track = try #require(try await after.loadTracks(withMediaType: .video).first)
        #expect(try await track.load(.preferredTransform) == Fixture.rotation)
        #expect(try await track.load(.naturalSize) == CGSize(width: Fixture.width, height: Fixture.height))
        let lengths = (try await before.load(.duration).seconds, try await after.load(.duration).seconds)
        #expect(abs(lengths.0 - lengths.1) < 0.05)
    }

    @Test("the copy is taken away with its folder")
    func discardRemovesCopy() async throws {
        let original = try await Fixture.video(.mov)
        defer { try? FileManager.default.removeItem(at: original) }
        let stripped = try await MetadataStripper.video(at: original)

        MetadataStripper.discard(stripped)
        #expect(!FileManager.default.fileExists(atPath: stripped.deletingLastPathComponent().path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: original.path(percentEncoded: false)))
    }
}

// MARK: - Fixtures

/// Pictures and clips carrying what a phone puts in them.
enum Fixture {
    static let width = 64
    static let height = 48
    /// "Rotate 90° to be seen the right way up" — what every portrait iPhone photo says.
    static let orientation = 6
    static let rotation = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 0, ty: 0)
    static let frames = 3
    static let delay = 0.2

    /// Strings that must not survive, each unlikely to turn up in a file by chance.
    static let secrets = ["55.7558", "iPhone 18 Pro", "SN-4242-SECRET", "Alice Liddell", "Tverskaya"]

    static func photo(_ type: UTType, tagged: Bool = true, width: Int = width, height: Int = height,
                      opaque: Bool = false) throws -> Data {
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try image(width: width, height: height, opaque: opaque),
                                   (tagged ? phoneProperties : [:]) as CFDictionary)
        try #require(CGImageDestinationFinalize(destination))
        return output as Data
    }

    static func animatedGIF() throws -> Data {
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, UTType.gif.identifier as CFString, frames, nil))
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
        ] as CFDictionary)
        var properties = phoneProperties
        properties[kCGImagePropertyGIFDictionary] = [kCGImagePropertyGIFDelayTime: delay]
        for _ in 0..<frames {
            CGImageDestinationAddImage(destination, try image(width: width, height: height, opaque: false),
                                       properties as CFDictionary)
        }
        try #require(CGImageDestinationFinalize(destination))
        return output as Data
    }

    static func properties(of data: Data) throws -> [String: Any] {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        return try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
    }

    static func type(of data: Data) -> UTType? {
        CGImageSourceCreateWithData(data as CFData, nil)
            .flatMap(CGImageSourceGetType)
            .flatMap { UTType($0 as String) }
    }

    private static var phoneProperties: [CFString: Any] {
        [
            kCGImagePropertyOrientation: orientation,
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 55.7558, kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 37.6173, kCGImagePropertyGPSLongitudeRef: "E",
            ],
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFMake: "Apple", kCGImagePropertyTIFFModel: "iPhone 18 Pro",
                kCGImagePropertyTIFFArtist: "Alice Liddell", kCGImagePropertyTIFFOrientation: orientation,
            ],
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifDateTimeOriginal: "2026:09:01 10:00:00",
                kCGImagePropertyExifBodySerialNumber: "SN-4242-SECRET",
            ],
            kCGImagePropertyIPTCDictionary: [kCGImagePropertyIPTCSubLocation: "Tverskaya"],
            kCGImagePropertyMakerAppleDictionary: ["8": [1, 1, 1]],
        ]
    }

    /// Half orange, and at a size worth compressing, a scatter of small squares — so a big picture
    /// has detail in it and is not a flat colour every encoder squeezes to nothing.
    private static func image(width: Int, height: Int, opaque: Bool) throws -> CGImage {
        let alpha = opaque ? CGImageAlphaInfo.noneSkipLast : .premultipliedLast
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                             bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.displayP3)!,
                                             bitmapInfo: alpha.rawValue))
        context.setFillColor(red: 1, green: 0.4, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        var seed: UInt64 = 42
        for _ in 0..<(width * height / 400) {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let x = Int(seed >> 33) % width, y = Int(seed >> 13) % height
            context.setFillColor(red: CGFloat(seed & 0xFF) / 255, green: CGFloat((seed >> 8) & 0xFF) / 255,
                                 blue: CGFloat((seed >> 16) & 0xFF) / 255, alpha: 1)
            context.fill(CGRect(x: x, y: y, width: 6, height: 6))
        }
        return try #require(context.makeImage())
    }

    // MARK: Video

    /// A one-second clip recorded sideways, with a phone's worth of movie and track metadata.
    static func video(_ type: AVFileType, width: Int = width, height: Int = height) async throws -> URL {
        let suffix = type == .mov ? "mov" : "mp4"
        let url = URL.temporaryDirectory.appending(component: "IMG_\(UUID().uuidString).\(suffix)")
        let writer = try AVAssetWriter(outputURL: url, fileType: type)
        writer.metadata = [
            item(.quickTimeMetadataLocationISO6709, "+55.7558+037.6173+150.000/"),
            item(.quickTimeMetadataModel, "iPhone 18 Pro"),
            item(.quickTimeMetadataCreationDate, "2026-09-01T10:00:00+0300"),
            item(.commonIdentifierAuthor, "Alice Liddell"),
        ]

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        input.transform = rotation
        input.metadata = [item(.quickTimeUserDataTrackName, "Tverskaya")]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        for frame in 0..<30 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            let pool = try #require(adaptor.pixelBufferPool)
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            adaptor.append(try #require(buffer), withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
        }
        input.markAsFinished()
        await writer.finishWriting()
        try #require(writer.status == .completed)
        return url
    }

    private static func item(_ identifier: AVMetadataIdentifier, _ value: String) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = identifier
        item.value = value as NSString
        item.dataType = kCMMetadataBaseDataType_UTF8 as String
        return item
    }
}
