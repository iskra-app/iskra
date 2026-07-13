import Foundation
import AVFoundation
import Observation
import IskraCore

/// Records a round video message.
///
/// The camera does not shoot square, so this records whatever the camera gives and
/// then crops the file to a true square before sending — see `SquareVideoExporter`
/// for why the bytes have to be square and not merely displayed round.
///
/// The sixty-second cap is enforced by `AVCaptureMovieFileOutput` itself rather than
/// by a timer we run, so a clip cannot overrun while the app is busy.
@MainActor
@Observable
public final class VideoNoteRecorder: NSObject {
    public enum State: Equatable {
        case idle
        case preparing
        /// The camera is live and the user can start recording.
        case ready
        case recording(secondsElapsed: TimeInterval)
        /// Cropping and uploading.
        case finishing
        case denied
        case unavailable
    }

    public private(set) var state: State = .idle

    /// Handed to the preview view. Nil until the camera is running.
    public private(set) var session: AVCaptureSession?

    /// Which camera is looking at you.
    ///
    /// The front one, to begin with. A video message is somebody talking to the person they
    /// are writing to, and the camera pointed at their face is the one they meant — needing to
    /// turn it round every single time would be the app not understanding what it is for. The
    /// back camera is a minute of the world in front of you, and it is a tap away.
    public private(set) var camera: AVCaptureDevice.Position = .front

    /// Held so it can be taken out again when the camera is turned round. The microphone
    /// stays where it is: swapping the lens has nothing to do with the sound.
    private var cameraInput: AVCaptureDeviceInput?

    private let output = AVCaptureMovieFileOutput()
    private var recordingStarted: Date?
    private var ticker: Task<Void, Never>?
    private var onRecorded: ((URL) async -> Void)?

    public override init() {
        super.init()
    }

    public var elapsed: TimeInterval {
        if case let .recording(seconds) = state { return seconds }
        return 0
    }

    /// How full the sixty seconds are, for the ring around the shutter.
    public var progress: Double {
        min(elapsed / VideoNote.maximumDuration, 1)
    }

    // MARK: - Camera

    /// Asks for the camera and microphone, then starts the preview.
    public func prepare() async {
        guard state == .idle else { return }
        state = .preparing

        guard await isPermitted(.video), await isPermitted(.audio) else {
            state = .denied
            return
        }

        let session = AVCaptureSession()
        session.sessionPreset = .high

        // The camera we want, or whatever this machine has if it has no notion of sides.
        guard let lens = Self.lens(facing: camera) ?? AVCaptureDevice.default(for: .video),
              let cameraInput = try? AVCaptureDeviceInput(device: lens),
              session.canAddInput(cameraInput)
        else {
            state = .unavailable
            return
        }
        session.addInput(cameraInput)
        self.cameraInput = cameraInput

        // A video message with no sound is not a video message — so a microphone that cannot
        // be attached stops the recording rather than quietly producing a silent one. This
        // used to be an `if let` that shrugged, and a shrug here is invisible: the user
        // records, watches the preview, sends, and only the person at the other end finds
        // out that nobody said anything.
        guard let microphone = AVCaptureDevice.default(for: .audio),
              let audioInput = try? AVCaptureDeviceInput(device: microphone),
              session.canAddInput(audioInput)
        else {
            Log.media.error("no microphone to record a video note with")
            state = .unavailable
            return
        }
        session.addInput(audioInput)

        guard session.canAddOutput(output) else {
            state = .unavailable
            return
        }
        session.addOutput(output)
        output.maxRecordedDuration = CMTime(seconds: VideoNote.maximumDuration, preferredTimescale: 600)
        recordUnmirrored()

        self.session = session

        // `startRunning()` blocks until the camera is up, so it must not run on the
        // main actor. AVCaptureSession is not Sendable, but Apple documents this call
        // as one to make off the main queue, so the hand-off is safe and said so here
        // rather than hidden behind a wrapper.
        nonisolated(unsafe) let starting = session
        await Task.detached { starting.startRunning() }.value

        state = .ready
    }

    /// Whether there is another camera to turn to. False on a Mac, and on anything else with
    /// one lens — a button that does nothing is worse than no button.
    public var canFlip: Bool {
        Self.lens(facing: .front) != nil && Self.lens(facing: .back) != nil
    }

    /// Turns the camera round — your face, or what you are looking at.
    ///
    /// Only between recordings. Swapping the lens mid-clip means taking the video input out of
    /// a session that is writing a file from it, and what comes out the other end is a
    /// recording with a seam in the middle: the picture jumps, the orientation flips, and the
    /// square crop is computed from a transform that was true for the *first* camera. The
    /// button is simply not offered while the red ring is filling, which is also what the user
    /// expects — nobody turns the camera round in the middle of a sentence.
    public func flip() {
        guard state == .ready, let session, let cameraInput else { return }

        let wanted: AVCaptureDevice.Position = camera == .front ? .back : .front
        guard let lens = Self.lens(facing: wanted),
              let replacement = try? AVCaptureDeviceInput(device: lens) else {
            Log.media.error("no camera facing the other way")
            return
        }

        // One configuration, committed once: the session tears down and rebuilds its
        // connections when this closes, and doing it in two steps would show the user the
        // moment in between — a preview with no camera behind it.
        session.beginConfiguration()
        session.removeInput(cameraInput)

        if session.canAddInput(replacement) {
            session.addInput(replacement)
            self.cameraInput = replacement
            camera = wanted
        } else {
            // Put back what was working. A composer with a dead preview is worse than one
            // pointing the wrong way.
            session.addInput(cameraInput)
            Log.media.error("the other camera would not attach")
        }

        session.commitConfiguration()

        // The connection was torn down and rebuilt by that configuration, and it came back with
        // the defaults. Say it again.
        recordUnmirrored()
    }

    /// The preview is a mirror. The recording is not. Both of those are on purpose, and they are
    /// opposites for a reason.
    ///
    /// A person looking at the front camera expects the mirror they have looked into every
    /// morning of their life: raise your right hand and the person on screen raises the hand on
    /// the same side. `AVCaptureVideoPreviewLayer` does that of its own accord and is left
    /// alone.
    ///
    /// What must *not* be mirrored is the file, and it is the file this method is about. Send a
    /// mirrored recording and the person watching sees you as nobody has ever seen you — and any
    /// writing in the shot, on a book, on a whiteboard, on a T-shirt, arrives backwards. The
    /// sender cannot catch it: the preview they were watching was mirrored, so it looked right
    /// to them and the mistake only exists at the other end.
    ///
    /// So it is set rather than left to the default. Apple's default happens to be what we want
    /// today, and a default is not a promise.
    private func recordUnmirrored() {
        guard let connection = output.connection(with: .video),
              connection.isVideoMirroringSupported else { return }

        connection.automaticallyAdjustsVideoMirroring = false
        connection.isVideoMirrored = false
    }

    public func start(onRecorded: @escaping (URL) async -> Void) {
        guard state == .ready else { return }

        self.onRecorded = onRecorded
        recordingStarted = .now
        state = .recording(secondsElapsed: 0)

        let url = URL.temporaryDirectory.appending(component: "\(UUID().uuidString).mov")
        output.startRecording(to: url, recordingDelegate: self)

        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, let started = recordingStarted else { return }
                if case .recording = state {
                    state = .recording(secondsElapsed: Date.now.timeIntervalSince(started))
                }
            }
        }
    }

    /// Stops and sends. The cap may also stop us on its own, which lands in the same
    /// delegate callback.
    public func stop() {
        guard case .recording = state else { return }
        state = .finishing
        output.stopRecording()
    }

    /// Throws the recording away. Used when the user backs out.
    public func cancel() {
        onRecorded = nil
        if case .recording = state {
            output.stopRecording()
        }
        teardown()
    }

    private func teardown() {
        ticker?.cancel()
        ticker = nil
        recordingStarted = nil

        if let session {
            nonisolated(unsafe) let stopping = session
            Task.detached { stopping.stopRunning() }
        }
        session = nil
        state = .idle
    }

    /// The ordinary camera on the side asked for. `AVCaptureDevice.default(for: .video)` cannot
    /// answer this — it hands back the back camera and has no way to be asked for the other one.
    ///
    /// Nil is a real answer and must stay one: a Mac has a single camera and it faces the user,
    /// so asking for the far side of it is a question with no answer. Papering over that with
    /// the default camera would give the Mac a "turn the camera round" button that turns
    /// nothing round.
    private static func lens(facing position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera],
                                         mediaType: .video,
                                         position: position).devices.first
    }

    private func isPermitted(_ media: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: media) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: media)
        default: false
        }
    }
}

extension VideoNoteRecorder: AVCaptureFileOutputRecordingDelegate {
    public nonisolated func fileOutput(_ output: AVCaptureFileOutput,
                                       didFinishRecordingTo outputFileURL: URL,
                                       from connections: [AVCaptureConnection],
                                       error: Error?) {
        // Reaching the sixty-second cap surfaces here as an error with a "successfully
        // finished" flag set. That is a completed recording, not a failure.
        let stoppedByCap = (error as? NSError)
            .flatMap { $0.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool } ?? false
        let recorded = (error == nil || stoppedByCap)

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { teardown() }

            guard recorded, let handler = onRecorded else {
                try? FileManager.default.removeItem(at: outputFileURL)
                return
            }

            defer { try? FileManager.default.removeItem(at: outputFileURL) }

            // Square it before it goes anywhere: roundness is carried by the pixels.
            guard let square = try? await SquareVideoExporter.square(outputFileURL) else { return }
            defer { try? FileManager.default.removeItem(at: square) }

            await handler(square)
        }
    }
}
