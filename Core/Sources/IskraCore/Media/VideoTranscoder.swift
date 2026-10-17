import Foundation
import AVFoundation
import CoreMedia
import UniformTypeIdentifiers

/// Re-encodes a video to a step of `MediaCompression`: fitted into its box, at no more than its
/// bit rate and frame rate, as H.264 and AAC in an MP4.
///
/// Reader and writer rather than an export session, because an export session has exactly one
/// dial — a preset — and no bit rate on it at all; and a preset whose size a clip already fits
/// hands the clip back untouched. A screen recording at 1280 x 808 and 8 Mbit/s came out of the
/// 720p preset at 8 Mbit/s. Here the rate is a number, and it is the one asked for.
///
/// The picture is drawn through a video composition, which does three things at once: it applies
/// the rotation a phone recorded the clip with (so the result is the right way up in any player,
/// including the ones that ignore a track's transform), it scales it into the box, and it converts
/// its colour to BT.709 — which is what turns an iPhone's HDR into ordinary video that does not
/// look washed out everywhere that cannot show HDR, which is almost everywhere.
///
/// With `stripsMetadata` only the pictures and the sound are carried; without it the movie's own
/// metadata is written into the new file. Track-level metadata and every other track stay behind
/// either way — they are a description of the old encoding, not of the video.
///
/// The copy lives where `VideoExport` puts its copies, under the original's name with `.mp4`, and
/// goes back to `VideoExport.discard` once sent.
enum VideoTranscoder {
    enum Failure: Error {
        case noVideo
        case cannotRead
        case cannotWrite
    }

    static func transcode(_ url: URL, level: MediaCompression, stripsMetadata: Bool) async throws -> URL {
        let asset = AVURLAsset(url: url)
        guard let video = try await asset.loadTracks(withMediaType: .video).first else { throw Failure.noVideo }
        let audio = try await asset.loadTracks(withMediaType: .audio).first
        let duration = try await asset.load(.duration)

        let natural = try await video.load(.naturalSize)
        let transform = try await video.load(.preferredTransform)
        let oriented = CGRect(origin: .zero, size: natural).applying(transform)
        guard oriented.width.isFinite, oriented.height.isFinite, oriented.width > 0, oriented.height > 0 else {
            throw Failure.noVideo
        }

        let target = fitted(oriented.size, into: level.videoBox)
        let scale = target.width / oriented.width
        let sourceRate = Double(try await video.load(.nominalFrameRate))
        let frameRate = sourceRate > 0 ? min(sourceRate, Double(level.maxFrameRate)) : Double(level.maxFrameRate)
        let sourceBitRate = Double(try await video.load(.estimatedDataRate))
        let bitRate = sourceBitRate > 0 ? min(Double(level.videoBitRate), sourceBitRate) : Double(level.videoBitRate)

        // The recorded rotation, moved back into the positive quarter it describes, then scaled.
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: video)
        layer.setTransform(transform
                            .concatenating(CGAffineTransform(translationX: -oriented.minX, y: -oriented.minY))
                            .concatenating(CGAffineTransform(scaleX: scale, y: scale)),
                           at: .zero)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        instruction.layerInstructions = [layer]

        let composition = AVMutableVideoComposition()
        composition.renderSize = target
        composition.frameDuration = CMTime(seconds: 1 / frameRate, preferredTimescale: 600)
        composition.instructions = [instruction]
        composition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        composition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        composition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2

        // Two readers, one a track, and that is the fix for a hang and not a style. One reader
        // serving both tracks holds them in one buffer: the writer interleaves, so it will not take
        // more sound until it has had pictures, and the reader will not hand over pictures until
        // somebody takes the sound it has read ahead. Both wait for ever, at no CPU at all.
        let pictureReader = try AVAssetReader(asset: asset)
        let pictures = AVAssetReaderVideoCompositionOutput(videoTracks: [video], videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        pictures.videoComposition = composition
        pictures.alwaysCopiesSampleData = false
        guard pictureReader.canAdd(pictures) else { throw Failure.cannotRead }
        pictureReader.add(pictures)

        var channels = 0
        if let audio { channels = try await channelCount(of: audio) }
        let pcm: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: audioSampleRate,
            AVNumberOfChannelsKey: channels,
        ]
        var sound: (reader: AVAssetReader, output: AVAssetReaderTrackOutput)?
        if let audio, channels > 0 {
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: audio, outputSettings: pcm)
            output.alwaysCopiesSampleData = false
            if reader.canAdd(output) {
                reader.add(output)
                sound = (reader, output)
            }
        }

        let output = try VideoExport.copyURL(for: url, as: .mp4)

        do {
            let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
            writer.shouldOptimizeForNetworkUse = true
            writer.metadata = stripsMetadata ? [] : try await asset.load(.metadata)

            let pictureInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Int(target.width),
                AVVideoHeightKey: Int(target.height),
                AVVideoColorPropertiesKey: [
                    AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                    AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
                ],
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: Int(bitRate),
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                    AVVideoExpectedSourceFrameRateKey: Int(frameRate.rounded()),
                    AVVideoMaxKeyFrameIntervalDurationKey: 2,
                ],
            ])
            pictureInput.expectsMediaDataInRealTime = false
            guard writer.canAdd(pictureInput) else { throw Failure.cannotWrite }
            writer.add(pictureInput)

            var soundInput: AVAssetWriterInput?
            if sound != nil {
                let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: audioSampleRate,
                    AVNumberOfChannelsKey: channels,
                    AVEncoderBitRateKey: level.audioBitRate * channels / 2,
                ])
                input.expectsMediaDataInRealTime = false
                guard writer.canAdd(input) else { throw Failure.cannotWrite }
                writer.add(input)
                soundInput = input
            }

            guard pictureReader.startReading() else { throw pictureReader.error ?? Failure.cannotRead }
            if let sound, !sound.reader.startReading() { throw sound.reader.error ?? Failure.cannotRead }
            guard writer.startWriting() else { throw writer.error ?? Failure.cannotWrite }
            writer.startSession(atSourceTime: .zero)

            // Both at once, each on its own queue: the writer interleaves, and feeding one track to
            // the end before starting the other would stall it.
            let picturePump = Pump(from: pictures, of: pictureReader, into: pictureInput, of: writer)
            let soundPump = sound.flatMap { sound in
                soundInput.map { Pump(from: sound.output, of: sound.reader, into: $0, of: writer) }
            }
            async let picturesDone: Void = picturePump.run()
            await soundPump?.run()
            await picturesDone

            for reader in [pictureReader, sound?.reader].compactMap({ $0 }) where reader.status == .failed {
                writer.cancelWriting()
                throw reader.error ?? Failure.cannotRead
            }
            // To the end of the original, not to the last sample written: a screen recording's
            // frames come when the screen changes, and one that sat still for its last half second
            // otherwise loses it.
            writer.endSession(atSourceTime: duration)
            await writer.finishWriting()
            guard writer.status == .completed else { throw writer.error ?? Failure.cannotWrite }
            // Given up on — a half-read file finished into a short one. Not to be sent, and not
            // to be left lying about either: it is somebody's video, in the clear.
            try Task.checkCancellation()

            if stripsMetadata, try await !MetadataStripper.isClean(video: output) {
                throw VideoExport.Failure.metadataRemained
            }
        } catch {
            VideoExport.discard(output)
            throw error
        }
        return output
    }

    /// 44.1 kHz — what AAC is happiest at, and what every player plays.
    private static let audioSampleRate = 44_100

    /// The source's channels, at most two: surround in a chat message is bits nobody hears.
    private static func channelCount(of track: AVAssetTrack) async throws -> Int {
        let descriptions = try await track.load(.formatDescriptions)
        let channels = descriptions.compactMap {
            CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mChannelsPerFrame
        }.first ?? 0
        return min(Int(channels), 2)
    }

    /// `size` scaled down to fit a box of long side by short side, keeping its shape, with even
    /// sides because H.264 insists on them. Never scaled up.
    static func fitted(_ size: CGSize, into box: (long: Int, short: Int)) -> CGSize {
        let long = max(size.width, size.height), short = min(size.width, size.height)
        let scale = min(1, CGFloat(box.long) / long, CGFloat(box.short) / short)
        let even = { (side: CGFloat) in max(2, (side * scale / 2).rounded() * 2) }
        return CGSize(width: even(size.width), height: even(size.height))
    }
}

/// Moves samples from a reader output into a writer input until either runs out.
///
/// `@unchecked Sendable` because the two AVFoundation objects it carries are not marked `Sendable`,
/// and they do not need to be: the writer calls back on one serial queue of its own, and nothing
/// else touches either of them while the pump runs.
private final class Pump: @unchecked Sendable {
    private let output: AVAssetReaderOutput
    private let reader: AVAssetReader
    private let input: AVAssetWriterInput
    private let writer: AVAssetWriter
    private let queue = DispatchQueue(label: "iskra.video-transcoder")
    private var finished = false

    init(from output: AVAssetReaderOutput, of reader: AVAssetReader,
         into input: AVAssetWriterInput, of writer: AVAssetWriter) {
        self.output = output
        self.reader = reader
        self.input = input
        self.writer = writer
    }

    /// Cancelling the task stops the reading, which ends the pump like the end of the file would —
    /// see `MediaPreparation.video`, whose deadline is what cancels it.
    func run() async {
        await withTaskCancellationHandler {
            await pump()
        } onCancel: {
            reader.cancelReading()
        }
    }

    private func pump() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            input.requestMediaDataWhenReady(on: queue) { [self] in
                guard !finished else { return }
                while input.isReadyForMoreMediaData {
                    guard reader.status == .reading, writer.status == .writing,
                          let buffer = output.copyNextSampleBuffer(),
                          input.append(buffer) else {
                        finished = true
                        input.markAsFinished()
                        continuation.resume()
                        return
                    }
                }
            }
        }
    }
}
