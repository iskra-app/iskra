import Foundation
import AVFoundation
import Observation
import IskraCore

/// Records a round video message.
///
/// The camera does not shoot square, so this records whatever the camera gives and then crops the
/// file to a true square before sending — see `SquareVideoExporter` for why the bytes have to be
/// square and not merely displayed round.
///
/// The frames go through an `AVAssetWriter` (`VideoNoteWriter`) rather than an
/// `AVCaptureMovieFileOutput`, and that is not an implementation detail: it is the only reason the
/// camera can be turned round in the middle of a sentence. The movie file output ends its file
/// whenever the session under it is reconfigured, which is what swapping a lens *is* — so with it,
/// flipping the camera ended the take, and the finished file it handed back was indistinguishable
/// from one the user had asked to send. See `VideoNoteWriter` for the whole of that story.
///
/// The sixty-second cap moved with the frames. It used to be `AVCaptureMovieFileOutput`'s to keep;
/// it is now enforced on the buffers themselves, on the capture queue, against the clock they
/// carry — which is the same guarantee it always was, and for the same reason: a clip must not
/// overrun because the app got busy.
@MainActor
@Observable
public final class VideoNoteRecorder: NSObject {
    public enum State: Equatable {
        case idle
        case preparing
        /// The camera is live and the user can start recording.
        case ready
        case recording(secondsElapsed: TimeInterval)
        /// Closing the file, cropping, uploading.
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

    /// Which way up the camera is, asked of the system rather than assumed.
    ///
    /// A phone shoots landscape and is held portrait; a Mac shoots the way it is bolted to the
    /// screen and is held nowhere. Hard-coding ninety degrees would give the phone an upright
    /// picture and the Mac a sideways one, and there is no constant that is right for both — so
    /// the question is put to the device, which is the only thing that knows.
    private var rotation: AVCaptureDevice.RotationCoordinator?

    /// Where the frames arrive, and where every part of writing them down happens. A serial queue,
    /// so a `finish` dispatched onto it cannot land in the middle of a frame being appended.
    private nonisolated let frames = DispatchQueue(label: "moscow.swag.iskra.videonote.frames")

    /// The two outputs the frames come down. `nonisolated(unsafe)` because the delegate callback
    /// has to tell them apart — it is handed *an* output and must know which — and that callback
    /// arrives on the capture queue. All it does there is compare identities, which is a read of a
    /// `let`; everything that configures them (`prepare`, `aim`) happens on the main actor.
    private nonisolated(unsafe) let videoOutput = AVCaptureVideoDataOutput()
    private nonisolated(unsafe) let audioOutput = AVCaptureAudioDataOutput()

    /// The take being written, if there is one. Held in a box rather than a property because it is
    /// read from the capture queue — by the sample buffer callbacks, which are the only things
    /// fast enough to care — and written from the main actor, which is where starting and stopping
    /// are decided.
    private nonisolated let take = Take()

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
    ///
    /// **Nothing here touches the main actor except the answer.** Building a capture session is
    /// slow in the way a user notices — opening the lens, attaching the microphone, and then
    /// `startRunning()`, which blocks outright until the camera is up — and every bit of it used to
    /// happen on the main actor, where it holds the first frame of the screen it belongs to. So the
    /// finger came down on the record button and, for the better part of a second, *nothing
    /// happened*: no blur, no circle, no controls, because the overlay could not be drawn while the
    /// thread that draws it was opening a camera. It came up all at once, already live, and looked
    /// like an app that had ignored the press. Now the overlay is on the screen before the camera
    /// is even asked for, and the picture arrives into a window that is already there.
    public func prepare() async {
        guard state == .idle else { return }
        state = .preparing

        guard await isPermitted(.video), await isPermitted(.audio) else {
            state = .denied
            return
        }

        let wanted = camera

        // The two outputs go to the queue that builds the session and are attached to it there.
        // `nonisolated(unsafe)` for the same reason `startRunning` needed it before: an
        // `AVCaptureOutput` is not `Sendable`, and nothing else is holding these yet — the session
        // they are about to belong to does not exist.
        nonisolated(unsafe) let outputs = (video: videoOutput, audio: audioOutput)

        // Said here rather than on the queue below: the delegate is this object, which is
        // main-actor isolated, and handing it into a detached closure is precisely the crossing
        // the compiler is right to refuse. It costs nothing where it stands — the outputs exist
        // before any session does.
        videoOutput.setSampleBufferDelegate(self, queue: frames)
        audioOutput.setSampleBufferDelegate(self, queue: frames)

        guard let built = await Task.detached(priority: .userInitiated) { () -> Camera? in
            let session = AVCaptureSession()
            session.sessionPreset = .high

            // The camera we want, or whatever this machine has if it has no notion of sides.
            guard let lens = Self.lens(facing: wanted) ?? AVCaptureDevice.default(for: .video),
                  let cameraInput = try? AVCaptureDeviceInput(device: lens),
                  session.canAddInput(cameraInput)
            else { return nil }
            session.addInput(cameraInput)

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
                return nil
            }
            session.addInput(audioInput)

            guard session.canAddOutput(outputs.video), session.canAddOutput(outputs.audio) else {
                return nil
            }
            session.addOutput(outputs.video)
            session.addOutput(outputs.audio)

            session.startRunning()
            return Camera(session: session, input: cameraInput, lens: lens)
        }.value else {
            state = .unavailable
            return
        }

        // Back on the main actor, where the session becomes something the screen can hold. `aim`
        // stays here: it configures the connection the frames come down, and it must be said again
        // after every flip, which happens here too.
        session = built.session
        cameraInput = built.input
        rotation = AVCaptureDevice.RotationCoordinator(device: built.lens, previewLayer: nil)
        aim()

        state = .ready
    }

    /// A camera that has been built and is running, carried back from the queue that built it.
    ///
    /// `@unchecked Sendable` and honestly so: none of the three has been handed to anybody yet —
    /// the session is running and nothing is looking at it, and the crossing happens once, in one
    /// direction, at the moment it is handed over to the main actor for good.
    private struct Camera: @unchecked Sendable {
        let session: AVCaptureSession
        let input: AVCaptureDeviceInput
        let lens: AVCaptureDevice
    }

    /// Whether there is another camera to turn to. False on a Mac, and on anything else with
    /// one lens — a button that does nothing is worse than no button.
    public var canFlip: Bool {
        Self.lens(facing: .front) != nil && Self.lens(facing: .back) != nil
    }

    public var isRecording: Bool {
        if case .recording = state { return true }
        return false
    }

    /// Turns the camera round — your face, or what you are looking at. Mid-recording and all,
    /// which is the only time it is any use: with hold-to-record the camera is always recording by
    /// the time it is on screen, so a button offered only "between takes" is a button nobody sees.
    ///
    /// The take is not interrupted, and needs no protecting. The writer is downstream of the
    /// session and indifferent to it: it is handed frames, and frames go on arriving. What changes
    /// is only what they are frames *of*. A clip flipped mid-sentence comes out as one file with a
    /// cut in it, which is what the user asked for by pressing the button.
    ///
    /// Two things still have to be said again afterwards, and both are said in `aim`: the rebuilt
    /// connection comes back with the system's defaults, so the mirroring and the rotation we
    /// chose have to be chosen a second time. Neither is a nicety — a mirrored file arrives
    /// backwards at the other end, and an unrotated one arrives on its side.
    public func flip() {
        guard state == .ready || isRecording, let session, let cameraInput else { return }

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
            rotation = AVCaptureDevice.RotationCoordinator(device: lens, previewLayer: nil)
        } else {
            // Put back what was working. A composer with a dead preview is worse than one
            // pointing the wrong way.
            session.addInput(cameraInput)
            Log.media.error("the other camera would not attach")
        }

        session.commitConfiguration()
        aim()
    }

    /// Which way up, and which way round — set on the connection the frames come down, and set
    /// again every time that connection is rebuilt.
    ///
    /// **The preview is a mirror. The recording is not.** Both are on purpose, and they are
    /// opposites for a reason. A person looking at the front camera expects the mirror they have
    /// looked into every morning of their life, and `AVCaptureVideoPreviewLayer` gives them one of
    /// its own accord. What must not be mirrored is the *file*: send a mirrored recording and the
    /// person watching sees you as nobody has ever seen you, and any writing in the shot — a book,
    /// a whiteboard, a T-shirt — arrives backwards. The sender cannot catch it, because the
    /// preview they were watching was mirrored and looked right to them. The mistake only exists
    /// at the other end.
    private func aim() {
        guard let connection = videoOutput.connection(with: .video) else { return }

        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }

        // Rotated here, on the buffers, rather than left to a transform written into the file.
        // The two are not equivalent once a second camera can join the take: a transform belongs
        // to the whole track and is decided once, and a lens that wants a different one has no way
        // to ask for it. Rotating the frames means every frame arrives the right way up whatever
        // produced it, and the file needs no transform at all.
        if let angle = rotation?.videoRotationAngleForHorizonLevelCapture,
           connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
        }
    }

    // MARK: - Recording

    public func start(onRecorded: @escaping (URL) async -> Void) {
        guard state == .ready else { return }

        // Asked of the microphone rather than guessed at. A guess that is wrong here is not a
        // worse recording, it is a video message with no sound in it.
        guard let settings = audioOutput.recommendedAudioSettingsForAssetWriter(writingTo: .mov) else {
            Log.media.error("the microphone would not say how it wants to be written down")
            state = .unavailable
            return
        }

        let url = URL.temporaryDirectory.appending(component: "\(UUID().uuidString).mov")

        // The cap arrives from the capture queue, on the frame that crosses sixty seconds. It is
        // routed back through `stop` and not handled there, because reaching the cap is a
        // recording that *ended properly* and has to go the same way as one the user let go of.
        guard let writing = VideoNoteWriter(url: url, audioSettings: settings, onCap: { [weak self] in
            Task { @MainActor in self?.stop() }
        }) else {
            state = .unavailable
            return
        }

        self.onRecorded = onRecorded
        recordingStarted = .now
        state = .recording(secondsElapsed: 0)

        frames.async { [take] in take.hold(writing) }

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

    /// Stops and sends. The cap may also stop us on its own, and lands here.
    public func stop() {
        guard case .recording = state else { return }
        state = .finishing

        ticker?.cancel()
        ticker = nil

        let handler = onRecorded
        onRecorded = nil

        Task {
            let url = await close()
            defer { teardown() }

            guard let url, let handler else {
                if let url { try? FileManager.default.removeItem(at: url) }
                return
            }
            defer { try? FileManager.default.removeItem(at: url) }

            // Square it before it goes anywhere: roundness is carried by the pixels.
            guard let square = try? await SquareVideoExporter.square(url) else { return }
            defer { try? FileManager.default.removeItem(at: square) }

            await handler(square)
        }
    }

    /// Throws the recording away. Used when the user backs out.
    public func cancel() {
        onRecorded = nil
        frames.async { [take] in take.claim()?.cancel() }
        teardown()
    }

    /// Closes the take on the queue that owns it, and comes back with the file — or with nothing,
    /// which is what a hold too short to catch a single frame produces.
    ///
    /// On `frames`, and that is the point of dispatching at all: it is the queue the buffers
    /// arrive on, so a file closed there cannot be closed halfway through appending to it.
    private nonisolated func close() async -> URL? {
        await withCheckedContinuation { continuation in
            frames.async { [take] in
                guard let writing = take.claim() else {
                    continuation.resume(returning: nil)
                    return
                }
                writing.finish { continuation.resume(returning: $0) }
            }
        }
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
    private nonisolated static func lens(facing position: AVCaptureDevice.Position) -> AVCaptureDevice? {
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

// MARK: - The take, and who is allowed to touch it

/// Holds the take being written, and hands it between the main actor and the capture queue.
///
/// The writer itself is only ever *used* on the capture queue — see `VideoNoteWriter`. What this
/// box exists for is the reference: it is set when the user starts recording and taken away when
/// they stop, both of which are decisions made on the main actor, while the frames arriving on the
/// capture queue need to find it a hundred times in between.
///
/// `claim` empties the box as it reads it. That is the point of it: the take can be finished
/// exactly once, and a cancel racing a cap racing a release must not all get hold of the same
/// writer and close it three times.
final class Take: @unchecked Sendable {
    private let lock = NSLock()
    private var writing: VideoNoteWriter?

    func hold(_ writing: VideoNoteWriter) {
        lock.withLock { self.writing = writing }
    }

    /// The take, for appending to. Left in the box.
    func current() -> VideoNoteWriter? {
        lock.withLock { writing }
    }

    /// The take, taken. Whoever gets it is the one who ends it, and there is only one of them.
    func claim() -> VideoNoteWriter? {
        lock.withLock {
            defer { writing = nil }
            return writing
        }
    }
}

// MARK: - The frames themselves

extension VideoNoteRecorder: AVCaptureVideoDataOutputSampleBufferDelegate,
                             AVCaptureAudioDataOutputSampleBufferDelegate {
    public nonisolated func captureOutput(_ output: AVCaptureOutput,
                                          didOutput sampleBuffer: CMSampleBuffer,
                                          from connection: AVCaptureConnection) {
        guard let writing = take.current() else { return }

        if output === videoOutput {
            writing.append(video: sampleBuffer)
        } else {
            writing.append(audio: sampleBuffer)
        }
    }
}
