import AVFoundation
import IskraCore

/// Makes the phone willing to make a noise.
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
enum PlaybackAudio {
    /// The result is logged rather than swallowed. A `try?` here is worth nothing: if this call
    /// fails the only symptom is silence, which is the very thing being debugged.
    static func prepare() {
        #if os(iOS)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback)
            try session.setActive(true)
        } catch {
            Log.media.error("the audio session refused playback: \(String(describing: error), privacy: .public)")
        }
        #endif
    }
}
