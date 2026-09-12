import AVFoundation
import IskraCore

/// One take, written frame by frame.
///
/// This exists because of a single thing `AVCaptureMovieFileOutput` will not do: survive its own
/// capture session being reconfigured. Turning the camera round means taking the video input out
/// of the session and putting another one in, and the movie file output responds by *finishing the
/// file* — not pausing, finishing. `pauseRecording()` is documented as if it would carry a
/// recording across that, and on a real device it does not. So the take ended, a complete file
/// landed in the recording delegate, and it looked exactly like a message somebody had asked to
/// send. For a while it *was* sent, which is the worst thing this app has done: a video of your
/// face, into a room, because you tapped a button that says "turn the camera round".
///
/// An asset writer has no opinion about the session at all. It is handed sample buffers and it
/// appends them; where they came from is not its business, and a lens swapped out from under it
/// changes nothing except what the next buffer looks like. The take goes on. That is the whole
/// reason for this file, and it is why the flip is now a cut in one clip rather than the end of it.
///
/// **Everything here happens on the capture queue, and only there.** The sample buffers arrive on
/// it, so appending does; starting and finishing are dispatched onto it by `VideoNoteRecorder` so
/// that they cannot land between two frames. That is the whole of the concurrency story, and it is
/// what the `@unchecked Sendable` below is claiming — not that this class is safe to touch from
/// anywhere, but that nothing touches it from anywhere else.
final class VideoNoteWriter: @unchecked Sendable {
    let url: URL

    private let writer: AVAssetWriter
    private let audio: AVAssetWriterInput

    /// Made from the first frame rather than up front, because the frame is what says how big it
    /// is. Which is also what makes a flip survivable: the take is committed to the dimensions of
    /// the camera that *started* it, and the writer scales whatever arrives afterwards to fit them
    /// — so a lens with a different sensor behind it does not end the recording, it just gets
    /// resized into the take that is already running.
    private var video: AVAssetWriterInput?

    /// When the take began, in the capture clock's own time. Everything before the first video
    /// frame is dropped, audio included: a file that starts with a second of sound over a black
    /// screen is a file that begins with a fault.
    private var began: CMTime = .invalid

    /// Shut, and refusing everything. Set by the cap and by `finish`, and it is what stops the
    /// frames that are already in flight on the capture queue from arriving after the door closed.
    private var isOver = false

    /// The sixty seconds, reached. Called once, from the capture queue.
    private let onCap: @Sendable () -> Void

    /// `audioSettings` are the settings the audio output itself recommends for this file type —
    /// asked of it rather than guessed at, because the answer depends on the hardware and a wrong
    /// guess is a video message nobody can hear.
    init?(url: URL, audioSettings: [String: Any], onCap: @escaping @Sendable () -> Void) {
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else {
            Log.media.error("a video note had nowhere to be written")
            return nil
        }

        self.url = url
        self.writer = writer
        self.onCap = onCap

        audio = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audio.expectsMediaDataInRealTime = true

        guard writer.canAdd(audio) else {
            Log.media.error("a video note would not take a soundtrack")
            return nil
        }
        writer.add(audio)
    }

    // MARK: - Taking the frames

    func append(video sample: CMSampleBuffer) {
        guard !isOver else { return }

        if video == nil {
            guard open(for: sample) else { return }
        }

        guard let video, writer.status == .writing else { return }

        let stamp = sample.presentationTimeStamp

        // The cap, enforced here rather than by the capture output — which is where it used to
        // live, and it lived there for a good reason: a clip cannot overrun while the app is
        // busy. It still cannot. This runs on the capture queue, on the frames themselves, and
        // reads the clock they carry rather than a clock we keep.
        if stamp.seconds - began.seconds >= VideoNote.maximumDuration {
            isOver = true
            onCap()
            return
        }

        // A frame the encoder is not ready for is dropped, not queued. Dropping one is invisible;
        // queueing them is how a recorder runs out of memory with the user's face in it.
        guard video.isReadyForMoreMediaData else { return }
        video.append(sample)
    }

    func append(audio sample: CMSampleBuffer) {
        guard !isOver,
              began.isValid,
              writer.status == .writing,
              audio.isReadyForMoreMediaData
        else { return }

        audio.append(sample)
    }

    /// The first frame is the one that decides what the file is: how big, and which way up.
    private func open(for sample: CMSampleBuffer) -> Bool {
        guard let format = sample.formatDescription else { return false }

        let size = CMVideoFormatDescriptionGetDimensions(format)
        guard size.width > 0, size.height > 0 else { return false }

        // `resizeAspectFill` is what lets a second camera join a take already in progress. Give
        // the input fixed dimensions and it will fit anything it is handed into them, cropping
        // from the middle rather than letterboxing — and the middle is the only part of a round
        // video message that survives the crop anyway.
        // Written down to the size the circle will actually be, rather than at whatever the
        // sensor hands over. The take is cropped to a 480-point square before it is sent, so
        // every pixel outside that square is encoded, written to disk, decoded and thrown away —
        // and the ones inside it are scaled down anyway. Scaling here keeps the aspect ratio the
        // camera gave us, so `resizeAspectFill` still has nothing to crop and a lens swapped
        // in mid-take is still fitted into the take that is already running.
        let (width, height) = Self.fitted(size)

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspectFill,
            // And compressed at a rate worked out from that size — see `VideoNote.bitsPerPixel`.
            // Left to itself the encoder writes a talking head in a small circle at the same
            // rate it would write a football match.
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: VideoNote.bitRate(width: width, height: height),
                AVVideoExpectedSourceFrameRateKey: VideoNote.frameRate,
            ],
        ])
        input.expectsMediaDataInRealTime = true

        guard writer.canAdd(input) else {
            Log.media.error("a video note would not take a picture")
            return false
        }
        writer.add(input)

        guard writer.startWriting() else {
            Log.media.error("a video note could not be started: \(String(describing: self.writer.error))")
            return false
        }

        began = sample.presentationTimeStamp
        writer.startSession(atSourceTime: began)
        video = input
        return true
    }

    /// The size a frame off the camera is written at: shrunk until its *shorter* side is the
    /// square the note will be cropped to, and never enlarged.
    ///
    /// The shorter side and not the longer one, because that is the side the crop keeps whole —
    /// `SquareVideoExporter` takes `min(width, height)` out of the middle. Fitting the longer
    /// side instead would arrive at a square that has to be scaled back up, which is a blurred
    /// video message with a smaller file as its only consolation.
    ///
    /// Both come back even. H.264 cannot encode an odd dimension in 4:2:0, and an encoder handed
    /// one either rounds it silently or refuses the whole input.
    static func fitted(_ size: CMVideoDimensions) -> (width: Int, height: Int) {
        let width = Int(size.width)
        let height = Int(size.height)
        let shorter = min(width, height)

        guard shorter > VideoNote.captureDimension else { return (even(width), even(height)) }

        let scale = Double(VideoNote.captureDimension) / Double(shorter)
        return (even(Int((Double(width) * scale).rounded())),
                even(Int((Double(height) * scale).rounded())))
    }

    private static func even(_ value: Int) -> Int { max(2, value - value % 2) }

    // MARK: - Ending it

    /// Closes the file and hands back where it is — or nothing, if there was never a take here to
    /// finish. Nothing is a real answer: a hold shorter than the camera takes to wake produces a
    /// writer that never saw a frame, and there is no message in that.
    func finish(_ done: @escaping @Sendable (URL?) -> Void) {
        guard writer.status == .writing, began.isValid else {
            cancel()
            done(nil)
            return
        }

        isOver = true
        video?.markAsFinished()
        audio.markAsFinished()

        // `finishWriting` calls back on a queue of the writer's own choosing, so the closure is
        // `@Sendable` and the writer is not. It is the writer's own callback about its own state,
        // arriving after it has stopped taking frames, and nothing else is left holding it.
        nonisolated(unsafe) let writer = writer
        let url = url
        writer.finishWriting {
            guard writer.status == .completed else {
                Log.media.error("a video note would not close: \(String(describing: writer.error))")
                try? FileManager.default.removeItem(at: url)
                done(nil)
                return
            }
            done(url)
        }
    }

    /// Thrown away, and the half-written file with it.
    func cancel() {
        isOver = true
        if writer.status == .writing { writer.cancelWriting() }
        try? FileManager.default.removeItem(at: url)
    }
}
