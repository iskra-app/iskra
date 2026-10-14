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
        /// The hold has taken and the microphone is being opened, which is not instant.
        ///
        /// Between this and `.recording` sits a round-trip to `mediaserverd` — `setCategory` and
        /// `setActive`, queued behind whatever else was asked of the audio session, so listening to
        /// a voice message and then recording one pays for the deactivation of the first before the
        /// second is even looked at — and then `AVAudioRecorder` opening a file. On a Mac that is
        /// nothing. On a phone it is most of a second, and it used to be a second of *nothing*: the
        /// composer showed a recording only from `.recording`, so the hold took, the phone tapped
        /// the hand, and then the screen sat still long enough for the user to conclude the app had
        /// not noticed and press again.
        ///
        /// So the state exists to be *shown*. The strip goes up the moment the hold commits, with
        /// the clock at zero, and the microphone arrives underneath it. What is not faked is the
        /// recording itself: `finish()` still hands back nothing from here, because there is
        /// nothing in the file yet.
        case starting
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

    // MARK: Warming up while the finger decides

    /// The microphone being opened ahead of time, from the moment a finger lands on the record
    /// button — see `prewarm()`. What it yields is a recorder ready to `record()` at once.
    private var warming: Task<Warm?, Never>?

    /// A recorder that has been made and primed, and the file it will write.
    ///
    /// `@unchecked Sendable` because it is made on a background thread and handed to the main
    /// actor once, by nobody else holding it — the one crossing it ever makes.
    private struct Warm: @unchecked Sendable {
        let recorder: AVAudioRecorder
        let url: URL
    }

    /// Opens the microphone's way while the press is still only a press.
    ///
    /// The second between a hold and a running clock was never the hold: it was the audio session
    /// waking — two round-trips to `mediaserverd` — and then `AVAudioRecorder` making its file and
    /// its encoder, all begun only once the hold had committed. Begun here, at touch-down, it runs
    /// while the finger is still deciding, and `start()` picks up what is ready. A tap throws it
    /// away again (`discardPrewarm()`).
    ///
    /// Only with permission already given: a permission alert is not something a tap that meant
    /// "switch to video" should raise.
    public func prewarm() {
        guard state == .idle, warming == nil,
              AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }
        warming = Task {
            await AudioSession.prepare(for: .recording)
            guard !Task.isCancelled else { return nil }
            return await Self.makeRecorder()
        }
    }

    /// The press was a tap after all: the primed recorder and the session go back.
    public func discardPrewarm() {
        guard state == .idle, let warming else { return }
        self.warming = nil
        warming.cancel()
        Task {
            if let warm = await warming.value {
                warm.recorder.deleteRecording()
            }
            AudioSession.release()
        }
    }

    /// Off the main thread: making the file and the encoder is the slow half of a recording
    /// starting, and on the main actor it was a frozen screen under the thumb.
    private static func makeRecorder() async -> Warm? {
        await Task.detached(priority: .userInitiated) { makeRecorderNow() }.value
    }

    nonisolated private static func makeRecorderNow() -> Warm? {
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
            // The file and the encoder, made now rather than inside `record()`.
            recorder.prepareToRecord()
            return Warm(recorder: recorder, url: url)
        } catch {
            Log.media.error("the recorder would not open: \(Log.describe(error), privacy: .public)")
            return nil
        }
    }

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

        // Said before the slow part rather than after it, and this is the whole of the fix for a
        // hold that appeared to do nothing for a second: everything below is the microphone being
        // opened, and none of it is worth making the user watch an unchanged screen through. See
        // `State.starting`.
        state = .starting

        // What the touch-down began, if it did — usually finished or nearly by now. Otherwise the
        // whole of it, here.
        let warm: Warm?
        if let warming {
            self.warming = nil
            warm = await warming.value
        } else {
            await AudioSession.prepare(for: .recording)
            warm = await Self.makeRecorder()
        }

        // And again on the other side of it. Waking the session is a round-trip to another process
        // (see `AudioSession`), and a thumb can be lifted while it is in flight — recording then
        // would leave a microphone running that nothing on screen admits to.
        guard generation == self.generation, state == .starting else {
            warm?.recorder.deleteRecording()
            AudioSession.release()
            return
        }

        do {
            guard let warm else { throw CocoaError(.fileWriteUnknown) }
            let recorder = warm.recorder
            let url = warm.url

            // `record` starts the audio unit, which is a wait on another process — off the main
            // actor for the same reason the recorder is made off it.
            let primed = warm
            let cap = Self.maximumDuration
            let started = await Task.detached(priority: .userInitiated) {
                primed.recorder.record(forDuration: cap)
            }.value
            guard generation == self.generation, state == .starting else {
                recorder.stop()
                recorder.deleteRecording()
                AudioSession.release()
                return
            }
            guard started else {
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
