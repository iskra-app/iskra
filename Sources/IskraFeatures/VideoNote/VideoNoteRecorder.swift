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

        guard let camera = AVCaptureDevice.default(for: .video),
              let cameraInput = try? AVCaptureDeviceInput(device: camera),
              session.canAddInput(cameraInput)
        else {
            state = .unavailable
            return
        }
        session.addInput(cameraInput)

        // A video message with no sound is not a video message.
        if let microphone = AVCaptureDevice.default(for: .audio),
           let audioInput = try? AVCaptureDeviceInput(device: microphone),
           session.canAddInput(audioInput) {
            session.addInput(audioInput)
        }

        guard session.canAddOutput(output) else {
            state = .unavailable
            return
        }
        session.addOutput(output)
        output.maxRecordedDuration = CMTime(seconds: VideoNote.maximumDuration, preferredTimescale: 600)

        self.session = session

        // `startRunning()` blocks until the camera is up, so it must not run on the
        // main actor. AVCaptureSession is not Sendable, but Apple documents this call
        // as one to make off the main queue, so the hand-off is safe and said so here
        // rather than hidden behind a wrapper.
        nonisolated(unsafe) let starting = session
        await Task.detached { starting.startRunning() }.value

        state = .ready
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
