import Testing
import Foundation
import AVFoundation
import CoreImage
import MatrixRustSDK
@testable import IskraCore

/// The whole video-note design rests on one claim: the file we send is *exactly*
/// square. Roundness is not a flag on the event — it cannot be, without hand-rolling
/// attachment encryption (see `VideoNote`) — so it is carried by the pixels, and a
/// clip that is 1080×1920 with a circular mask over it would fool nobody but us.
///
/// These tests make a real portrait video and put it through the exporter.
struct SquareVideoExporterTests {
    @Test("a portrait clip comes out exactly square")
    func cropsPortraitToSquare() async throws {
        let source = try await makeVideo(width: 1080, height: 1920, seconds: 1)
        defer { try? FileManager.default.removeItem(at: source) }

        // Sanity: the input really is not square, or this test proves nothing.
        let before = try await dimensions(of: source)
        #expect(before.width != before.height)

        let square = try await SquareVideoExporter.square(source, side: 480)
        defer { try? FileManager.default.removeItem(at: square) }

        let after = try await dimensions(of: square)
        #expect(after.width == 480)
        #expect(after.height == 480)
    }

    @Test("a landscape clip comes out exactly square too")
    func cropsLandscapeToSquare() async throws {
        let source = try await makeVideo(width: 1280, height: 720, seconds: 1)
        defer { try? FileManager.default.removeItem(at: source) }

        let square = try await SquareVideoExporter.square(source, side: 480)
        defer { try? FileManager.default.removeItem(at: square) }

        let after = try await dimensions(of: square)
        #expect(after.width == after.height)
    }

    /// The exported file must be one the receiving side actually recognises as round.
    /// This closes the loop: exporter out, detector in.
    @Test("the exported clip is recognised as a video note")
    func exportedClipIsDetectedAsAVideoNote() async throws {
        let source = try await makeVideo(width: 1080, height: 1920, seconds: 1)
        defer { try? FileManager.default.removeItem(at: source) }

        let square = try await SquareVideoExporter.square(source, side: 480)
        defer { try? FileManager.default.removeItem(at: square) }

        let info = await MediaMetadata.video(at: square)
        let width = try #require(info.width)
        let height = try #require(info.height)
        let duration = try #require(info.duration)

        #expect(width == height)
        #expect(duration <= VideoNote.maximumDuration)

        // Exactly the check `TimelineMapper` runs on an incoming message.
        let content = VideoMessageContent(
            filename: "note.mp4",
            caption: nil,
            formattedCaption: nil,
            source: try MediaSource.fromUrl(url: "mxc://example.org/abc"),
            info: VideoInfo(duration: duration,
                            height: height,
                            width: width,
                            mimetype: info.mimeType,
                            size: info.size,
                            thumbnailInfo: nil,
                            thumbnailSource: nil,
                            blurhash: nil)
        )
        #expect(VideoNote.isVideoNote(content))
    }

    // MARK: - Making a real video to crop

    private func dimensions(of url: URL) async throws -> CGSize {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let size = try await track.load(.naturalSize).applying(try await track.load(.preferredTransform))
        return CGSize(width: abs(size.width), height: abs(size.height))
    }

    /// Writes a short clip of solid colour at the requested size.
    private func makeVideo(width: Int, height: Int, seconds: Int) async throws -> URL {
        let url = URL.temporaryDirectory.appending(component: "\(UUID().uuidString).mp4")

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ])
        input.expectsMediaDataInRealTime = false

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB]
        )

        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let frames = seconds * 30
        for frame in 0..<frames {
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32ARGB, nil, &buffer)
            let pixelBuffer = try #require(buffer)

            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
                memset(base, 128, CVPixelBufferGetBytesPerRow(pixelBuffer) * height)
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(5))
            }
            adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
        }

        input.markAsFinished()
        await writer.finishWriting()

        return url
    }
}
