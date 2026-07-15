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
        /// The microphone stopped without being asked to, and what was said up to that point is
        /// still worth sending.
        ///
        /// Three things do this and the user cannot tell them apart: the five-minute cap, a phone
        /// call, and the app being sent to the background — in every one of them iOS takes the
        /// microphone away and `AVAudioRecorder` simply stops. Until this case existed the app did
        /// not notice: `state` stayed `.recording`, so the composer went on showing a pulsing red
        /// dot over a frozen clock, and the person went on talking into a microphone that had been
        /// switched off minutes ago.
        ///
        /// A separate case rather than going straight back to `.idle`, because the recording is
        /// *good* — it is simply finished. Throwing it away because iOS took the microphone would
        /// lose the user their message; showing a live recording that is not live is a lie. What
        /// is left is to say so, and let them send it.
        case stopped
        case denied
        case unavailable
    }

    public private(set) var state: State = .idle

    /// How long has actually been recorded — which is not how long ago the recording started.
    ///
    /// Taken from `AVAudioRecorder.currentTime`, sampled while the microphone is running, rather
    /// than from the wall clock. The two agree right up until the recording is interrupted, and
    /// then they part company completely: a call that lasts three minutes puts three minutes on
    /// the wall clock and not one second into the file. A voice message that announced itself as
    /// 3:40 and played twelve seconds of audio is what the wall clock produced.
    ///
    /// `currentTime` cannot simply be read at the end, either — a stopped `AVAudioRecorder`
    /// reports zero — so it is remembered as it goes.
    public private(set) var elapsed: TimeInterval = 0

    /// The shape of what has been said so far, 0...1. Drawn live in the composer, so the user can
    /// see the microphone is hearing them — a recorder that shows nothing is one you have to
    /// trust, and a voice message you recorded into a dead microphone is only discovered by the
    /// person you sent it to.
    public private(set) var waveform: [Float] = []

    private var recorder: AVAudioRecorder?
    private var url: URL?
    private var ticker: Task<Void, Never>?

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

    /// Bumped every time the user lets go — see `cancel()` and `finish()`.
    ///
    /// `start()` has an `await` in the middle of it, and the first time it is ever called that
    /// await is the *system's microphone permission alert*: a modal that takes the finger off the
    /// button by definition. All of `cancel()`, `finish()` and the composer's own state ran while
    /// `state` was still `.idle` — so they found no recorder, did nothing, and were satisfied. And
    /// then `start()` resumed, the permission came back granted, and it opened the microphone.
    ///
    /// A live recording, behind a screen showing no recording, that nobody is holding. This is how
    /// the first voice message anyone ever tries to send used to go.
    private var generation = 0

    public func start() async {
        guard state == .idle else { return }

        let generation = self.generation

        guard await isPermitted() else {
            guard generation == self.generation else { return }
            state = .denied
            return
        }

        // Let go while the alert was up, or while the audio session was waking. There is nobody
        // holding this any more, and there is nothing on screen that would show it if we recorded.
        guard generation == self.generation, state == .idle else { return }

        await AudioSession.prepare(for: .recording)

        // And again on the other side of it. Waking the session is a round-trip to another process
        // (see `AudioSession`), and a thumb can be lifted while it is in flight — recording then
        // would leave a microphone running that nothing on screen admits to.
        guard generation == self.generation, state == .idle else {
            AudioSession.release()
            return
        }

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
                // The session was activated just above and is now ours for nothing — hand it back,
                // or whatever was playing before the recording never comes back. The two guards
                // higher up already do this; the recorder-failed paths used to walk past it.
                AudioSession.release()
                state = .unavailable
                return
            }

            self.recorder = recorder
            self.url = url
            waveform = []
            elapsed = 0
            state = .recording

            startSampling()
        } catch {
            Log.media.error("the recorder would not open: \(Log.describe(error), privacy: .public)")
            AudioSession.release()
            state = .unavailable
        }
    }

    /// Stops, and hands back what was recorded — the file, how long it is, and its shape.
    ///
    /// Nil where there is nothing worth sending. A recording shorter than half a second is a
    /// finger that brushed the button, not a message, and sending it would put a bubble in the
    /// conversation saying nothing at all.
    public func finish() -> Recording? {
        // The finger is up. Whatever `start()` is still doing on the other side of the permission
        // alert, it is no longer wanted — see `generation`.
        generation += 1

        defer { reset() }

        // `.stopped` as well as `.recording`: the microphone may have been taken away by the cap,
        // by a phone call or by the app going to the background, and what was said before that is
        // a message the user still means to send.
        guard state == .recording || state == .stopped, let recorder, let url else { return nil }

        // What is *in the file*, not how long ago we started. See `elapsed`: the two are the same
        // number until something interrupts the recording, and then the wall clock goes on counting
        // a microphone that is switched off.
        let duration = min(elapsed, Self.maximumDuration)
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
        generation += 1

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
        state = .idle

        // And the microphone is handed back. See `AudioSession.release()` — without it, whatever
        // was playing before the recording never comes back.
        AudioSession.release()
    }

    private func startSampling() {
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.samplingInterval)
                guard let self, let recorder else { return }

                // Whether the microphone is still ours — asked *first*, and acted on rather than
                // merely noticed. It stops without telling anybody: at the five-minute cap, when a
                // call comes in, when the app is put in the background. This used to be a bare
                // `return` at the bottom of the loop, and returning is exactly what left the
                // composer showing a live recording that had ended: a pulsing red dot, a frozen
                // clock, and a person still talking.
                guard recorder.isRecording else {
                    stoppedByItself()
                    return
                }

                recorder.updateMeters()
                waveform.append(Self.level(fromDecibels: recorder.averagePower(forChannel: 0)))

                // What is in the file, not what is on the clock. See `elapsed`.
                elapsed = min(recorder.currentTime, Self.maximumDuration)
            }
        }
    }

    /// The microphone was taken away. Say so, and keep what was said.
    private func stoppedByItself() {
        guard state == .recording else { return }
        state = .stopped
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

    private func isPermitted() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .audio)
        default: false
        }
    }
}
