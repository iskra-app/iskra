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

    /// A still with no measurements is a still the SDK throws away: `sendVideo` attaches the
    /// thumbnail only when it is given the bytes *and* a `ThumbnailInfo` describing them, and
    /// given one without the other it silently sends neither. That is what made every circle
    /// in the timeline grey, and nothing else in the app would have noticed.
    @Test("a video is described with a still the SDK will actually attach")
    func describesItsThumbnail() async throws {
        let source = try await makeVideo(width: 1080, height: 1920, seconds: 1)
        defer { try? FileManager.default.removeItem(at: source) }

        let square = try await SquareVideoExporter.square(source, side: 480)
        defer { try? FileManager.default.removeItem(at: square) }

        let thumbnail = try #require(await MediaMetadata.video(at: square).thumbnail)

        #expect(thumbnail.width > 0)
        #expect(thumbnail.height > 0)
        #expect(thumbnail.size > 0)
        #expect(thumbnail.mimeType == "image/jpeg")
    }

    /// The crop must not cost the clip its sound. A video note is somebody talking, and a
    /// silent one is a stranger mouthing at the camera — which is exactly what shipped: the
    /// exporter builds a video composition, and it is easy to write one that reaches the
    /// receiver with the picture intact and the audio track quietly dropped on the floor.
    @Test("the sound survives the crop")
    func keepsTheAudioTrack() async throws {
        let source = try await makeVideo(width: 1080, height: 1920, seconds: 1, withSound: true)
        defer { try? FileManager.default.removeItem(at: source) }

        // Sanity: the input really does have sound, or this test proves nothing.
        let before = try await AVURLAsset(url: source).loadTracks(withMediaType: .audio)
        #expect(before.count == 1)

        let square = try await SquareVideoExporter.square(source, side: 480)
        defer { try? FileManager.default.removeItem(at: square) }

        let after = try await AVURLAsset(url: square).loadTracks(withMediaType: .audio)
        #expect(after.count == 1)
    }

    /// The corners are what the person filming never saw: they framed their face in a round
    /// viewfinder, and everything outside it — the room, the doorway, whoever walked past —
    /// went into the file anyway, where every other Matrix client renders it. So the exporter
    /// paints them out, and this is the check that it did: black in the corner, picture in the
    /// middle. The source clip is a solid mid-grey precisely so that "black" means the mask and
    /// nothing else.
    @Test("what falls outside the circle is painted out of the file")
    func blacksOutTheCorners() async throws {
        let source = try await makeVideo(width: 1080, height: 1920, seconds: 1)
        defer { try? FileManager.default.removeItem(at: source) }

        let square = try await SquareVideoExporter.square(source, side: 480)
        defer { try? FileManager.default.removeItem(at: square) }

        let frame = try await firstFrame(of: square)

        // Deep in a corner, and just inside it — both are outside the circle.
        #expect(try brightness(of: frame, x: 4, y: 4) < 16)
        #expect(try brightness(of: frame, x: 40, y: 40) < 16)

        // The middle is still the video.
        #expect(try brightness(of: frame, x: 240, y: 240) > 64)

        // And so is the edge of the circle the app masks the player with: the black is cut by
        // a *wider* circle, so it never reaches what we draw. This is the point of the
        // overshoot, and without it this pixel is a dark fringe on somebody's cheek.
        #expect(try brightness(of: frame, x: 240, y: 6) > 64)
    }

    /// A minute of video is the largest thing this app sends without being asked to, and until
    /// somebody put a number on it nobody was watching the number. The export is the last hand
    /// the file passes through, and it is the one place where "quality" was set to the preset
    /// that spends the most — on a 480-point circle of a face, over somebody's mobile data.
    ///
    /// The clip here is *noise*, which is the point: a flat grey test video compresses to nearly
    /// nothing whatever the preset says, so it would pass this check while proving no part of
    /// it. Random pixels are the worst input an encoder can be given, so what this measures is
    /// the ceiling rather than the average — and the ceiling is what a bit rate *is*.
    ///
    /// Three times the nominal rate, because the preset is not a bit-rate setting and cannot be
    /// held to one exactly (see `SquareVideoExporter`). It is wide enough that ordinary video
    /// never comes near it and narrow enough to fail if this ever goes back to
    /// `AVAssetExportPresetHighestQuality`, which measures about twice this on the same clip.
    @Test("a video note is compressed on its way out")
    func compressesWhatItSends() async throws {
        let source = try await makeVideo(width: 1080, height: 1920, seconds: 2, noisy: true)
        defer { try? FileManager.default.removeItem(at: source) }

        let square = try await SquareVideoExporter.square(source, side: 480)
        defer { try? FileManager.default.removeItem(at: square) }

        let track = try #require(try await AVURLAsset(url: square).loadTracks(withMediaType: .video).first)
        let rate = try await track.load(.estimatedDataRate)

        #expect(rate <= Float(VideoNote.bitRate(width: 480, height: 480) * 3))
    }

    // MARK: - Making a real video to crop

    private func firstFrame(of url: URL) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .positiveInfinity
        return try await generator.image(at: CMTime(value: 1, timescale: 2)).image
    }

    /// 0–255 at one pixel, so a test can say "black" and "not black" and mean it.
    private func brightness(of image: CGImage, x: Int, y: Int) throws -> Int {
        var pixel: [UInt8] = [0, 0, 0, 0]
        let context = try #require(CGContext(data: &pixel,
                                             width: 1,
                                             height: 1,
                                             bitsPerComponent: 8,
                                             bytesPerRow: 4,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y),
                                       width: image.width, height: image.height))
        return (Int(pixel[0]) + Int(pixel[1]) + Int(pixel[2])) / 3
    }

    private func dimensions(of url: URL) async throws -> CGSize {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let size = try await track.load(.naturalSize).applying(try await track.load(.preferredTransform))
        return CGSize(width: abs(size.width), height: abs(size.height))
    }

    /// Writes a short clip of solid colour at the requested size, with — when asked — an
    /// audio track of silence on it. Silence is enough: what is being tested is whether the
    /// track is still *there*, not what is on it.
    private func makeVideo(width: Int, height: Int, seconds: Int, withSound: Bool = false, noisy: Bool = false) async throws -> URL {
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

        let audio: AVAssetWriterInput? = withSound ? AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000
        ]) : nil
        if let audio {
            audio.expectsMediaDataInRealTime = false
            writer.add(audio)
        }

        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let frames = seconds * 30
        for frame in 0..<frames {
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32ARGB, nil, &buffer)
            let pixelBuffer = try #require(buffer)

            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
                let bytes = CVPixelBufferGetBytesPerRow(pixelBuffer) * height
                if noisy {
                    // Every byte different from the last, and different again in the next frame:
                    // the encoder is given nothing to predict and nothing to repeat.
                    arc4random_buf(base, bytes)
                } else {
                    memset(base, 128, bytes)
                }
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(5))
            }
            adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
        }

        if let audio {
            for second in 0..<seconds {
                while !audio.isReadyForMoreMediaData {
                    try await Task.sleep(for: .milliseconds(5))
                }
                audio.append(try silence(samples: 44_100,
                                         at: CMTime(value: CMTimeValue(second), timescale: 1)))
            }
            audio.markAsFinished()
        }

        input.markAsFinished()
        await writer.finishWriting()

        return url
    }

    /// A second of nothing, in the shape `AVAssetWriter` will accept: 16-bit mono PCM.
    private func silence(samples: Int, at time: CMTime) throws -> CMSampleBuffer {
        var format = AudioStreamBasicDescription(mSampleRate: 44_100,
                                                 mFormatID: kAudioFormatLinearPCM,
                                                 mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
                                                 mBytesPerPacket: 2,
                                                 mFramesPerPacket: 1,
                                                 mBytesPerFrame: 2,
                                                 mChannelsPerFrame: 1,
                                                 mBitsPerChannel: 16,
                                                 mReserved: 0)

        var description: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil,
                                       asbd: &format,
                                       layoutSize: 0,
                                       layout: nil,
                                       magicCookieSize: 0,
                                       magicCookie: nil,
                                       extensions: nil,
                                       formatDescriptionOut: &description)

        let bytes = samples * 2
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil,
                                           memoryBlock: nil,
                                           blockLength: bytes,
                                           blockAllocator: nil,
                                           customBlockSource: nil,
                                           offsetToData: 0,
                                           dataLength: bytes,
                                           flags: kCMBlockBufferAssureMemoryNowFlag,
                                           blockBufferOut: &block)
        let blockBuffer = try #require(block)
        CMBlockBufferFillDataBytes(with: 0, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: bytes)

        var sample: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil,
            dataBuffer: blockBuffer,
            formatDescription: try #require(description),
            sampleCount: CMItemCount(samples),
            presentationTimeStamp: time,
            packetDescriptions: nil,
            sampleBufferOut: &sample
        )

        return try #require(sample)
    }
}
