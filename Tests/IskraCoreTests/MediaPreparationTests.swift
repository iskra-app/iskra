import Testing
import Foundation
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
@testable import IskraCore

/// What the two settings do to a photo or a video on its way out, one combination at a time — and
/// that a video note is outside both.
///
/// Uses the phone-shaped fixtures from `MetadataStripperTests`.
@Suite
struct MediaPreparationTests {
    private static let everything = MediaSettings(stripsMetadata: true, compresses: true, compression: .strong)
    private static let nothing = MediaSettings(stripsMetadata: false, compresses: false, compression: .strong)

    // MARK: - Settings

    @Test("nothing chosen yet means both on, at the middle step")
    func defaults() throws {
        let defaults = try #require(UserDefaults(suiteName: "media-settings-\(UUID().uuidString)"))
        #expect(MediaSettings.current(defaults) == MediaSettings(stripsMetadata: true, compresses: true,
                                                                 compression: .balanced))

        defaults.set(false, forKey: MediaSettings.stripsMetadataKey)
        defaults.set(false, forKey: MediaSettings.compressesKey)
        defaults.set(MediaCompression.light.rawValue, forKey: MediaSettings.compressionKey)
        #expect(MediaSettings.current(defaults) == MediaSettings(stripsMetadata: false, compresses: false,
                                                                 compression: .light))
    }

    @Test("a video note is always stripped and never compressed a second time")
    func videoNoteIgnoresSettings() {
        #expect(MediaSettings.videoNote.stripsMetadata)
        #expect(!MediaSettings.videoNote.compresses)
    }

    // MARK: - Photos

    @Test("compressed, a big photo comes out no longer than its step, as a JPEG, the right way up",
          arguments: MediaCompression.allCases)
    func photoIsCompressed(level: MediaCompression) throws {
        // 5000 x 3000 stored, orientation 6: it is a portrait photo, 3000 wide and 5000 tall.
        let original = try Fixture.photo(.jpeg, width: 5000, height: 3000, opaque: true)
        let settings = MediaSettings(stripsMetadata: true, compresses: true, compression: level)
        let sent = try #require(MediaPreparation.photo(original, filename: "IMG_0042.JPG", settings: settings))

        let properties = try Fixture.properties(of: sent.data)
        let width = try #require(properties[kCGImagePropertyPixelWidth as String] as? Int)
        let height = try #require(properties[kCGImagePropertyPixelHeight as String] as? Int)
        #expect(height == min(level.maxPhotoSide, 5000))
        #expect(width < height, "the orientation belongs in the pixels, or the photo arrives on its side")
        #expect((properties[kCGImagePropertyOrientation as String] as? Int ?? 1) == 1)

        #expect(Fixture.type(of: sent.data) == .jpeg)
        #expect(sent.filename == "IMG_0042.jpeg")
        #expect(sent.data.count < original.count)
        #expect(MetadataStripper.isClean(photo: sent.data))
    }

    @Test("compressed with metadata kept, the location is still there")
    func compressionCanKeepMetadata() throws {
        let original = try Fixture.photo(.jpeg, width: 4000, height: 3000, opaque: true)
        let settings = MediaSettings(stripsMetadata: false, compresses: true, compression: .strong)
        let sent = try #require(MediaPreparation.photo(original, filename: "a.jpg", settings: settings))

        let properties = try Fixture.properties(of: sent.data)
        #expect(properties[kCGImagePropertyGPSDictionary as String] != nil)
        #expect(properties[kCGImagePropertyPixelWidth as String] as? Int == 960)
        #expect(sent.data.count < original.count)
    }

    @Test("stripped but not compressed, the photo keeps its size and format")
    func strippingAloneKeepsSize() throws {
        let original = try Fixture.photo(.heic, width: 4000, height: 3000, opaque: true)
        let settings = MediaSettings(stripsMetadata: true, compresses: false, compression: .strong)
        let sent = try #require(MediaPreparation.photo(original, filename: "a.heic", settings: settings))

        #expect(MetadataStripper.isClean(photo: sent.data))
        #expect(try Fixture.properties(of: sent.data)[kCGImagePropertyPixelWidth as String] as? Int == 4000)
        #expect(Fixture.type(of: sent.data) == .heic)
    }

    @Test("with both off the photo goes byte for byte as it came")
    func bothOffSendsOriginal() throws {
        let original = try Fixture.photo(.jpeg, width: 2000, height: 1500)
        #expect(MediaPreparation.photo(original, filename: "a.jpg", settings: Self.nothing)
                == PhotoFile(data: original, filename: "a.jpg"))
    }

    @Test("a picture with transparency stays a PNG")
    func transparencyStaysPNG() throws {
        let original = try Fixture.photo(.png, width: 3000, height: 2000)
        let sent = try #require(MediaPreparation.photo(original, filename: "shot.png", settings: Self.everything))
        #expect(Fixture.type(of: sent.data) == .png)
        #expect(sent.filename == "shot.png")
    }

    @Test("a small photo is not made bigger by being compressed")
    func smallPhotoIsNotEnlarged() throws {
        let original = try Fixture.photo(.jpeg, tagged: false)
        let sent = try #require(MediaPreparation.photo(original, filename: "a.jpg", settings: Self.everything))
        #expect(sent.data.count <= original.count)
        #expect(try Fixture.properties(of: sent.data)[kCGImagePropertyPixelWidth as String] as? Int == Fixture.width)
    }

    @Test("an animation is not flattened into its first frame")
    func animationIsNotCompressed() throws {
        let sent = try #require(MediaPreparation.photo(try Fixture.animatedGIF(), filename: "cat.gif",
                                                       settings: Self.everything))
        let source = try #require(CGImageSourceCreateWithData(sent.data as CFData, nil))
        #expect(CGImageSourceGetCount(source) == Fixture.frames)
        #expect(MetadataStripper.isClean(photo: sent.data))
    }

    // MARK: - Videos

    @Test("compressed and stripped in one pass: an MP4 inside its step, with nothing in it")
    func videoIsCompressedAndStripped() async throws {
        let original = try await Fixture.video(.mov, width: 1920, height: 1080)
        defer { try? FileManager.default.removeItem(at: original) }

        let smaller = try await VideoTranscoder.transcode(original, level: .strong, stripsMetadata: true)
        defer { VideoExport.discard(smaller) }

        #expect(smaller.pathExtension == "mp4")
        #expect(smaller.deletingPathExtension().lastPathComponent == original.deletingPathExtension().lastPathComponent)
        #expect(try await MetadataStripper.isClean(video: smaller))
        let track = try #require(try await AVURLAsset(url: smaller).loadTracks(withMediaType: .video).first)
        // Re-encoding puts the rotation into the pixels, so what is checked is what is *shown*: the
        // clip was recorded sideways at 1920 x 1080, so it is a portrait 540 x 960.
        let shown = try await track.load(.naturalSize).applying(try await track.load(.preferredTransform))
        #expect(CGSize(width: abs(shown.width), height: abs(shown.height)) == CGSize(width: 540, height: 960))

        // The rate is a ceiling the encoder was told, not a preset's guess. Some slack, because a
        // one-second clip is mostly its first keyframe.
        let rate = try await track.load(.estimatedDataRate)
        #expect(rate <= Float(MediaCompression.strong.videoBitRate) * 1.5, "\(rate)")
    }

    @Test("a video is fitted into its step's box by its long side and its short side, never enlarged")
    func videoBox() {
        let box = MediaCompression.strong.videoBox
        #expect(VideoTranscoder.fitted(CGSize(width: 1920, height: 1080), into: box) == CGSize(width: 960, height: 540))
        #expect(VideoTranscoder.fitted(CGSize(width: 1080, height: 1920), into: box) == CGSize(width: 540, height: 960))
        #expect(VideoTranscoder.fitted(CGSize(width: 4032, height: 3024), into: box) == CGSize(width: 720, height: 540))
        #expect(VideoTranscoder.fitted(CGSize(width: 640, height: 480), into: box) == CGSize(width: 640, height: 480))
        #expect(VideoTranscoder.fitted(CGSize(width: 1280, height: 721), into: MediaCompression.balanced.videoBox)
                == CGSize(width: 1278, height: 720))
    }

    @Test("compressed with metadata kept, the location is still there")
    func videoCompressionCanKeepMetadata() async throws {
        let original = try await Fixture.video(.mov, width: 1920, height: 1080)
        defer { try? FileManager.default.removeItem(at: original) }

        let smaller = try await VideoTranscoder.transcode(original, level: .strong, stripsMetadata: false)
        defer { VideoExport.discard(smaller) }

        let metadata = try await AVURLAsset(url: smaller).load(.metadata)
        #expect(!metadata.isEmpty)
    }

    @Test("a video note goes stripped, at its own size, from a copy")
    func videoNoteIsStrippedOnly() async throws {
        let original = try await Fixture.video(.mp4)
        defer { try? FileManager.default.removeItem(at: original) }

        let prepared = try await MediaPreparation.video(original, settings: .videoNote)
        defer { prepared.discard() }

        #expect(prepared.isCopy)
        #expect(try await MetadataStripper.isClean(video: prepared.url))
        let track = try #require(try await AVURLAsset(url: prepared.url).loadTracks(withMediaType: .video).first)
        #expect(try await track.load(.naturalSize) == CGSize(width: Fixture.width, height: Fixture.height))
    }

    @Test("with both off the video goes as it is, and is not taken away afterwards")
    func bothOffSendsOriginalVideo() async throws {
        let original = try await Fixture.video(.mov)
        defer { try? FileManager.default.removeItem(at: original) }

        let prepared = try await MediaPreparation.video(original, settings: Self.nothing)
        #expect(prepared.url == original)
        #expect(!prepared.isCopy)
        prepared.discard()
        #expect(FileManager.default.fileExists(atPath: original.path(percentEncoded: false)))
    }
}
