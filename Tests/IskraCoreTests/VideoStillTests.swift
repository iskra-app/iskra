import Testing
import Foundation
import AVFoundation
import CoreGraphics
import ImageIO
@testable import IskraCore

/// The still a video note shows in the timeline before anyone plays it.
///
/// A phone camera opens black. It spends a few tenths of a second settling its exposure, and
/// those frames are in the file like any other — so a thumbnail taken at time zero is a black
/// circle, every time, for every video note the app sends. The message arrived, the picture of
/// it was a hole, and nothing failed anywhere.
///
/// These tests film exactly that: a clip that begins black and then turns to picture.
struct VideoStillTests {
    @Test("a clip that opens black is not represented by its black")
    func skipsTheCameraWakingUp() async throws {
        let url = try await makeVideo(seconds: 2, blackFor: 0.3)
        defer { try? FileManager.default.removeItem(at: url) }

        // Sanity: the first frame really is black, or this test proves nothing.
        #expect(try await brightness(ofFrameAt: .zero, in: url) < 8)

        let still = try #require(await MediaMetadata.still(at: url))

        #expect(try brightness(ofJPEG: still) > 64)
    }

    /// The thumbnail the SDK actually attaches to the outgoing message comes down the same
    /// path, and it is the one the receiver sees.
    @Test("the attached thumbnail has a picture in it")
    func describesItWithAWokenFrame() async throws {
        let url = try await makeVideo(seconds: 2, blackFor: 0.3)
        defer { try? FileManager.default.removeItem(at: url) }

        let thumbnail = try #require(await MediaMetadata.video(at: url).thumbnail)

        #expect(try brightness(ofJPEG: thumbnail.data) > 64)
    }

    /// A clip shorter than the half-second we look in at is still a clip, and it still needs a
    /// picture. Asking for a frame past the end of it returns nothing at all, and nothing is a
    /// grey hole in the timeline — so the middle of a short clip is what comes back instead.
    @Test("a clip shorter than half a second still gets a still")
    func aShortClipStillGetsOne() async throws {
        let url = try await makeVideo(seconds: 0.3, blackFor: 0)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(await MediaMetadata.still(at: url) != nil)
    }

    // MARK: - Filming a camera waking up

    /// A square clip that is black for `blackFor` seconds and mid-grey afterwards.
    private func makeVideo(seconds: Double, blackFor: Double) async throws -> URL {
        let url = URL.temporaryDirectory.appending(component: "\(UUID().uuidString).mp4")
        let side = 240
        let rate: Int32 = 30

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: side,
            AVVideoHeightKey: side
        ])
        input.expectsMediaDataInRealTime = false

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB]
        )
        writer.add(input)

        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        for frame in 0..<Int(seconds * Double(rate)) {
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, side, side, kCVPixelFormatType_32ARGB, nil, &buffer)
            let pixelBuffer = try #require(buffer)

            let isBlack = Double(frame) / Double(rate) < blackFor

            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
                memset(base, isBlack ? 0 : 160, CVPixelBufferGetBytesPerRow(pixelBuffer) * side)
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(5))
            }
            adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: rate))
        }

        input.markAsFinished()
        await writer.finishWriting()

        return url
    }

    // MARK: - Reading the light back out

    private func brightness(ofFrameAt time: CMTime, in url: URL) async throws -> Int {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return try mean(of: try await generator.image(at: time).image)
    }

    private func brightness(ofJPEG data: Data) throws -> Int {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        return try mean(of: try #require(CGImageSourceCreateImageAtIndex(source, 0, nil)))
    }

    /// The mean of the middle of the picture, 0–255.
    private func mean(of image: CGImage) throws -> Int {
        let side = 8
        var pixels = [UInt8](repeating: 0, count: side * side * 4)

        try pixels.withUnsafeMutableBytes { bytes in
            let context = try #require(CGContext(data: bytes.baseAddress,
                                                 width: side,
                                                 height: side,
                                                 bitsPerComponent: 8,
                                                 bytesPerRow: side * 4,
                                                 space: CGColorSpaceCreateDeviceRGB(),
                                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: -side / 2, y: -side / 2, width: side * 2, height: side * 2))
        }

        var total = 0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            total += Int(pixels[i]) + Int(pixels[i + 1]) + Int(pixels[i + 2])
        }
        return total / (side * side * 3)
    }
}
