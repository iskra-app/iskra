import AVFoundation
import Observation
import IskraCore

/// Records a voice message.
///
/// AAC in an m4a container, which is not what Matrix's own clients send — they send Ogg Opus —
/// and is what every Apple platform can record and play without a third-party codec. The event
/// carries its own mime type, so a receiver is told what it is getting rather than left to guess;
/// what this costs is that a client which only ever learned to play Opus will show the message
/// and not play it. That is the honest trade, and the alternative is shipping an Opus encoder to
/// avoid it.
///
/// The waveform is computed here, while the sound is going in, and travels with the message.
/// That is the only way both ends can see the same picture: the receiver has not downloaded the
/// audio — the whole point of the bubble is that they can decide from the shape and the length
/// whether to listen — so they cannot draw it themselves.
@MainActor
@Observable
public final class VoiceRecorder {
    public enum State: Equatable {
        case idle
        case recording
        case denied
        case unavailable
    }

    public private(set) var state: State = .idle
    public private(set) var elapsed: TimeInterval = 0

    /// The shape of what has been said so far, 0...1. Drawn live in the composer, so the user can
    /// see the microphone is hearing them — a recorder that shows nothing is one you have to
    /// trust, and a voice message you recorded into a dead microphone is only discovered by the
    /// person you sent it to.
    public private(set) var waveform: [Float] = []

    private var recorder: AVAudioRecorder?
    private var url: URL?
    private var ticker: Task<Void, Never>?
    private var startedAt: Date?

    public init() {}

    /// How many samples the event carries. Matrix's own convention, and what other clients draw.
    public static let sampleCount = 128

    /// How often the microphone's level is read. Slow enough to be nothing, fast enough that a
    /// recording of any normal length has more samples than the 128 it needs, so the waveform is
    /// an average of what was said rather than a series of snapshots of it.
    private static let samplingInterval = Duration.milliseconds(50)

    /// The longest a voice message may be. Not the SDK's rule — it has none — but a bubble's: a
    /// twenty-minute voice message is not a message, it is a podcast nobody agreed to.
    public static let maximumDuration: TimeInterval = 300

    public func start() async {
        guard state == .idle else { return }

        guard await isPermitted() else {
            state = .denied
            return
        }

        prepareToRecord()

        let url = URL.temporaryDirectory.appending(component: "\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            // Voice, not music. 24 kHz mono at 48 kbps is what a phone call has always been and
            // is perfectly clear; twice that would double the upload for something nobody would
            // hear the difference in.
            AVSampleRateKey: 24_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 48_000,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        do {
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.isMeteringEnabled = true

            guard recorder.record(forDuration: Self.maximumDuration) else {
                Log.media.error("the microphone would not start")
                state = .unavailable
                return
            }

            self.recorder = recorder
            self.url = url
            startedAt = .now
            waveform = []
            elapsed = 0
            state = .recording

            startSampling()
        } catch {
            Log.media.error("the recorder would not open: \(String(describing: error), privacy: .public)")
            state = .unavailable
        }
    }

    /// Stops, and hands back what was recorded — the file, how long it is, and its shape.
    ///
    /// Nil where there is nothing worth sending. A recording shorter than half a second is a
    /// finger that brushed the button, not a message, and sending it would put a bubble in the
    /// conversation saying nothing at all.
    public func finish() -> Recording? {
        defer { reset() }

        guard state == .recording, let recorder, let startedAt, let url else { return nil }

        // Measured from the clock, not from `recorder.currentTime`. The cap is enforced by
        // `record(forDuration:)`, which *stops the recorder* when it is reached — and a stopped
        // `AVAudioRecorder` reports a `currentTime` of zero. So a voice message that ran the full
        // five minutes would have come out as a recording of length nothing, and been thrown away
        // for being too short to be a message.
        let duration = min(Date.now.timeIntervalSince(startedAt), Self.maximumDuration)
        recorder.stop()

        guard duration >= Self.minimumDuration else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }

        return Recording(url: url, duration: duration, waveform: resampled())
    }

    /// Throws it away — the swipe out of a message you have changed your mind about halfway
    /// through. Nothing is sent and the file goes.
    public func cancel() {
        recorder?.stop()
        if let url { try? FileManager.default.removeItem(at: url) }
        reset()
    }

    /// A finished recording, on its way to `TimelineStore.send(voice:duration:waveform:)`.
    ///
    /// The file is plaintext on disk and must be deleted once it has been sent — see how
    /// `RoomView` uses this.
    public struct Recording: Sendable {
        public let url: URL
        public let duration: TimeInterval
        public let waveform: [Float]
    }

    /// Below this, it was a slip of the thumb.
    private static let minimumDuration: TimeInterval = 0.5

    private func reset() {
        ticker?.cancel()
        ticker = nil
        recorder = nil
        url = nil
        startedAt = nil
        state = .idle
    }

    private func startSampling() {
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.samplingInterval)
                guard let self, let recorder, let startedAt else { return }

                recorder.updateMeters()
                waveform.append(Self.level(fromDecibels: recorder.averagePower(forChannel: 0)))
                elapsed = Date.now.timeIntervalSince(startedAt)

                // The cap is enforced by `record(forDuration:)`, which stops the recorder — so
                // the only thing left to do here is notice, and let the screen send what there is.
                if !recorder.isRecording {
                    return
                }
            }
        }
    }

    /// Decibels to something a bar height can be drawn from.
    ///
    /// `averagePower` is in dBFS: 0 is as loud as the microphone goes and −160 is silence. That
    /// scale is logarithmic and drawing it straight produces a waveform that is nearly full
    /// height the whole way along, because ordinary speech sits in the top handful of decibels.
    /// The floor is therefore put at −50 dB — quiet speech, not the noise of the room — and what
    /// is above it is spread across the full height.
    private static func level(fromDecibels decibels: Float) -> Float {
        let floor: Float = -50
        guard decibels > floor else { return 0 }
        return min(1, (decibels - floor) / -floor)
    }

    /// The samples taken, squeezed into the 128 the event carries.
    ///
    /// An *average* per bucket rather than every 30th sample. Picking one sample in thirty means
    /// the waveform is 30 snapshots of an instant, and a word landing between two of them simply
    /// does not appear — the bar for a second of speech comes out at whatever the microphone
    /// happened to hear at the moment it was asked.
    private func resampled() -> [Float] {
        guard !waveform.isEmpty else { return Array(repeating: 0, count: Self.sampleCount) }

        // A message too short to fill the buckets keeps what it has, padded out — better a
        // waveform that stops halfway than one stretched over silence that was never recorded.
        guard waveform.count > Self.sampleCount else {
            return waveform + Array(repeating: 0, count: Self.sampleCount - waveform.count)
        }

        let bucket = Double(waveform.count) / Double(Self.sampleCount)

        return (0..<Self.sampleCount).map { index in
            let start = Int(Double(index) * bucket)
            let end = min(waveform.count, Int(Double(index + 1) * bucket))
            guard start < end else { return waveform[min(start, waveform.count - 1)] }

            let slice = waveform[start..<end]
            return slice.reduce(0, +) / Float(slice.count)
        }
    }

    /// The session has to be told a microphone is about to be used, or it hands back silence.
    ///
    /// `playAndRecord` rather than `record`, because the app plays as well — and a session left
    /// in `record` makes the next voice message the user *listens* to come out of nowhere. What
    /// puts the sound back on the speaker afterwards is `PlaybackAudio.prepare()`, which every
    /// player calls.
    private func prepareToRecord() {
        #if os(iOS)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker])
            try session.setActive(true)
        } catch {
            Log.media.error("the audio session refused the microphone: \(String(describing: error), privacy: .public)")
        }
        #endif
    }

    private func isPermitted() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .audio)
        default: false
        }
    }
}
