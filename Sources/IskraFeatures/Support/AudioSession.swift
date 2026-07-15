import AVFoundation
import IskraCore

/// Makes the phone willing to make a noise, and does it off the main thread.
///
/// Two separate things would otherwise silence a message, and both of them look exactly like a
/// broken player. The app's default category is `soloAmbient`, which the ring switch mutes — a
/// video somebody pressed play on is not ambient. And recording a video note or a voice message
/// leaves the session in `playAndRecord`, whose default output is the *earpiece*: the sound is
/// there, playing into the side of the phone, and to the user holding it at arm's length there
/// is no sound at all.
///
/// One place, because every one of the three things this app plays — a video note, an opened
/// video, a voice message — hits both problems, and a copy of this in each of them is three
/// chances to fix only two.
///
/// ## Why none of it runs on the main actor
///
/// `setCategory` and `setActive` read like property setters and are nothing of the kind: each is a
/// synchronous round-trip to `mediaserverd`, another process, which may be in the middle of tearing
/// down a capture session or handing the microphone to somebody else when it is asked. Called from
/// the main thread it *blocks* the main thread for as long as that takes — AVFoundation says so
/// itself, in the log, every time ("This method can lead to UI unresponsiveness…"), and the app was
/// hanging on exactly that: stop a video note, press play, and the activation waits on a daemon
/// that is still dismantling the recording it was just asked to dismantle.
///
/// So the calls go onto a queue of their own and the main actor *awaits* them instead of standing
/// on them. Awaiting is what makes it safe as well as smooth: the player must not start before the
/// category is set, or the ring switch mutes it after all, and the fix for a hang must not quietly
/// reintroduce the silence this type exists to prevent.
///
/// The queue is serial, and strictly first-in-first-out, which is the whole reason it is written as
/// a chain of tasks rather than as an `actor`. Awaiting an actor gives no order at all — reentrant
/// callers resume in whatever order the runtime likes — and the order is the one thing that matters
/// here. Finishing a recording releases the session and pressing play activates it, and those two
/// arrive within a frame of each other; let them land the wrong way round and the release turns off
/// the session the playback just turned on, which is silence again, from the code that was supposed
/// to cure it.
@MainActor
enum AudioSession {
    /// What the session is wanted for.
    enum Use {
        /// Anything the app plays: a voice message, a video note, a video opened full-screen.
        case playback
        /// The microphone. `playAndRecord` rather than `record`, because the app plays as well —
        /// a session left in `record` makes the next voice message the user *listens* to come out
        /// of nowhere. `.defaultToSpeaker` is what keeps it off the earpiece.
        case recording
    }

    /// Configures the session and waits until it really is configured.
    ///
    /// The wait is a suspension, not a block: the main actor is free while `mediaserverd` thinks
    /// about it, and the caller still knows the session is live by the time it has a player.
    static func prepare(for use: Use) async {
        await serially { apply(use) }.value
    }

    /// Gives the microphone back, and tells whoever was using the speaker that they may have it.
    ///
    /// This was missing entirely once, and what it cost was somebody else's music. Recording
    /// activates the session in `playAndRecord`, and a session nobody deactivates keeps a paused
    /// podcast paused — not for a moment, but until the app is killed.
    ///
    /// Not awaited, and deliberately: this is cleanup on the way out of a recording, nobody is
    /// waiting to hear anything, and `finish()` is called from a gesture that should end the moment
    /// the finger lifts. It is still *ordered* against everything else on the queue, which is the
    /// part that matters.
    static func release() {
        serially { relinquish() }
    }

    // MARK: - The queue

    /// The tail of the chain. Every new piece of work waits on the last one and becomes the tail
    /// itself, which is a serial queue built out of the two things `Task` already guarantees.
    private static var pending: Task<Void, Never> = Task {}

    @discardableResult
    private static func serially(_ work: @escaping @Sendable () -> Void) -> Task<Void, Never> {
        let previous = pending
        let next = Task.detached(priority: .userInitiated) {
            await previous.value
            work()
        }
        pending = next
        return next
    }

    // MARK: - The session itself

    /// The result is logged rather than swallowed. A `try?` here is worth nothing: if this call
    /// fails the only symptom is silence, which is the very thing being debugged.
    nonisolated private static func apply(_ use: Use) {
        #if os(iOS)
        do {
            let session = AVAudioSession.sharedInstance()
            switch use {
            case .playback:
                try session.setCategory(.playback, mode: .moviePlayback)
            case .recording:
                try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker])
            }
            try session.setActive(true)
        } catch {
            Log.media.error("the audio session refused \(String(describing: use), privacy: .public): \(Log.describe(error), privacy: .public)")
        }
        #endif
    }

    nonisolated private static func relinquish() {
        #if os(iOS)
        do {
            // `notifyOthersOnDeactivation` is the half that actually resumes them. Deactivating
            // without it releases the session and tells nobody, and a paused podcast has no way to
            // know it may start again.
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            // Worth a line and not worth a sentence to the user: the recording itself is fine, and
            // this only decides whether their music comes back on its own.
            Log.media.error("the audio session would not stand down: \(Log.describe(error), privacy: .public)")
        }
        #endif
    }
}
