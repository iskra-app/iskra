import AVFoundation
import Observation
import SwiftUI
import IskraCore

/// Playing one voice message: the download, the player, and how far through it is.
///
/// The sibling of `VideoPlayback`, and deliberately not the same class. A video is a picture
/// that moves and needs a layer to draw into; a voice message is a *shape* — a waveform that
/// fills up as it plays — and what it needs from a player is a number between 0 and 1, sampled
/// often enough to look continuous. `AVAudioPlayer` gives that directly, and `AVPlayer` would
/// make it a time observer and a `CMTime` conversion for no benefit.
///
/// One at a time, across every conversation, for the same reason video notes are: the device
/// has one pair of speakers, and two voices talking over each other means neither is being
/// listened to.
@MainActor
@Observable
final class AudioPlayback {
    private(set) var isPlaying = false
    private(set) var isLoading = false
    private(set) var failed = false

    /// How far through, 0...1. What the waveform fills to.
    private(set) var progress: Double = 0

    /// The decrypted file. Nothing reads it: it is held so that the plaintext stays on disk
    /// while the player has it open, and is deleted when it does not.
    private var file: MediaFile?
    private var player: AVAudioPlayer?

    /// What moves the bar. A timer rather than a delegate callback, because there is no
    /// callback for "still playing" — only for "finished".
    /// `nonisolated(unsafe)` so that `deinit` — which is not on the main actor — can reach it.
    /// Every other access is on the main actor, and the deinit's is a hop back to it.
    nonisolated(unsafe) private var ticker: Timer?

    @MainActor
    private static weak var current: AudioPlayback?

    /// The end of the message. `AVAudioPlayer` has a delegate for this and a delegate is an
    /// object, so it is one: a closure box, kept alive by the player it belongs to.
    private var finish: FinishListener?

    /// Play, pause, or pick up where you left off.
    ///
    /// The middle one used to be missing, and the button lied about it: the glyph said
    /// `pause.fill` and the VoiceOver label said "Pause", while the code called `stop()` —
    /// which rewinds to zero and throws the decrypted file away. Two minutes forty into a
    /// three-minute message, "pause" meant "start again, and download it again to do it".
    ///
    /// Pausing is not scrubbing, and the argument against a draggable handle (see
    /// `VoiceMessageView` — a message is not a track) never applied to it. Somebody says your
    /// name while you are listening; you stop to answer them; you carry on. That is the whole
    /// of it, and the glyph was right all along.
    func toggle(_ attachment: Attachment, using loader: MediaLoader?) async {
        if isPlaying {
            pause()
        } else if player != nil {
            resume()
        } else {
            await play(attachment, using: loader)
        }
    }

    /// Holds the place. The player and the decrypted file both stay — the plaintext is on disk
    /// for exactly as long as this message is the one in your hand, which is the same rule as
    /// while it is playing, and `stop()` is still what enforces the end of it.
    private func pause() {
        player?.pause()
        isPlaying = false

        ticker?.invalidate()
        ticker = nil
    }

    private func resume() {
        guard let player else { return }

        // Somebody else may have started talking while this one was paused, and the speakers
        // are one pair — so they give way, exactly as they do in `play`.
        //
        // `!== self` is load-bearing and not defensive noise. A paused message is still the
        // *current* one, so an unguarded `Self.current?.stop()` here would stop **us**: nil the
        // player, drop the file, rewind to zero — and resuming would silently do nothing at all,
        // which is precisely the bug this method exists to fix, reintroduced one line further in.
        if Self.current !== self {
            Self.current?.stop()
        }
        Self.current = self

        player.play()
        isPlaying = true
        startTicking()
    }

    private func play(_ attachment: Attachment, using loader: MediaLoader?) async {
        guard !isLoading, let loader else { return }

        isLoading = true
        failed = false
        defer { isLoading = false }

        // Whoever was talking gives way immediately, rather than when this download finishes.
        Self.current?.stop()
        Self.current = self

        do {
            let file = try await loader.file(for: attachment)

            // Somebody pressed a different message while this one was coming down, and it has
            // the speakers now. Coming up at this point would put two voices on at once.
            guard Self.current === self else { return }

            self.file = file

            await AudioSession.prepare(for: .playback)

            // Awaited, so a second press may have landed in the meantime and taken the speakers.
            guard Self.current === self else { return }

            let player = try AVAudioPlayer(contentsOf: file.url)
            let finish = FinishListener { [weak self] in self?.stop() }
            player.delegate = finish
            self.finish = finish
            self.player = player

            player.play()
            isPlaying = true
            startTicking()
        } catch {
            Log.media.error("the voice message would not play: \(Log.describe(error), privacy: .public)")
            failed = true
        }
    }

    /// Stops, rewinds, and lets the bytes go.
    ///
    /// The progress goes back to zero rather than staying where it stopped, and that is the
    /// right behaviour for a *message*: a voice message is a thing you listen to, not a track
    /// you scrub. Pressing it again means "from the beginning".
    func stop() {
        player?.stop()
        player = nil
        finish = nil
        file = nil

        ticker?.invalidate()
        ticker = nil

        isPlaying = false
        progress = 0

        if Self.current === self {
            Self.current = nil
        }
    }

    private func startTicking() {
        ticker?.invalidate()

        // Twenty times a second: fast enough that a bar filling looks like it is filling, slow
        // enough that it is not a timer worth thinking about.
        let ticker = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let player = self.player else { return }
                self.progress = player.duration > 0 ? player.currentTime / player.duration : 0
            }
        }

        // `.common`, and this is the whole reason the timer is built by hand rather than by
        // `scheduledTimer`. That convenience adds it in `.default` mode, and a run loop in
        // `.default` mode is a run loop that is *not* tracking a scroll: drag the conversation
        // while a voice message is playing and the timer simply stops firing. The sound carries on
        // — it is on another thread entirely — while the bar underneath it freezes, and then jumps
        // when the finger comes up. It reads as the audio having stuck, which is precisely the one
        // thing that has not happened.
        RunLoop.main.add(ticker, forMode: .common)
        self.ticker = ticker
    }

    /// A repeating `Timer` is owned by the run loop and never stops on its own. Every ordinary way
    /// out of a playback calls `stop()`, which invalidates it — but "ordinary" is doing a lot of
    /// work in that sentence, and a playback that is simply let go of has no way out at all: the
    /// timer goes on firing twenty times a second, for the life of the app, into a `[weak self]`
    /// that is nil.
    ///
    /// Two awkward things, and both are the reason this is four lines instead of one.
    /// `deinit` on a `@MainActor` class is *not* on the main actor, so it cannot read main-actor
    /// state — hence `nonisolated(unsafe)` on the local. And `Timer` must be invalidated on the run
    /// loop it was added to, which is why it is hopped back to the main queue rather than
    /// invalidated where we stand.
    deinit {
        nonisolated(unsafe) let timer = ticker
        guard timer != nil else { return }

        DispatchQueue.main.async { timer?.invalidate() }
    }
}

/// `AVAudioPlayer` reports the end of a clip through a delegate, and a delegate has to be an
/// object. This is the smallest object that will do.
///
/// It hops to the main actor rather than asserting it is already there. `AVAudioPlayer` calls
/// its delegate on the run loop the player was created on, which here is the main one — but
/// "here" is a fact about this call site rather than a promise from the framework, and
/// `assumeIsolated` on a promise nobody made is a crash waiting for the day it stops being true.
private final class FinishListener: NSObject, AVAudioPlayerDelegate, @unchecked Sendable {
    private let onFinish: @Sendable @MainActor () -> Void

    init(onFinish: @escaping @Sendable @MainActor () -> Void) {
        self.onFinish = onFinish
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in onFinish() }
    }
}
