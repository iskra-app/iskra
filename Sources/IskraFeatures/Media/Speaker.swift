import Foundation

/// The device's single pair of speakers, held by one playback at a time — of *either* kind.
///
/// A voice message fills a waveform; a video note plays a circle. They are different classes for
/// good reasons (`AudioPlayback` and `VideoPlayback` want different things from a player), and each
/// used to keep its own `static weak var current` to enforce "one at a time". Each did — for its
/// own kind. But the thing being shared is not "the voice messages" or "the video notes"; it is the
/// speakers, of which the device has one pair, and two independent floors meant a voice message and
/// a video note could play over each other while each class's own comment promised that could not
/// happen. One floor, held across both, is the fact of the hardware rather than of either class.
@MainActor
protocol SpeakerClaimant: AnyObject {
    /// Give the speakers up: stop playing, and let go of whatever is held to play.
    func stop()
}

@MainActor
enum Speaker {
    private static weak var holder: SpeakerClaimant?

    /// Take the speakers. Whoever had them — of either kind — is stopped first, unless it is us:
    /// a paused voice message resuming is still the current holder, and stopping it would stop the
    /// very thing trying to start. This is the `!== self` guard each class used to carry by hand.
    static func claim(_ claimant: SpeakerClaimant) {
        if holder !== claimant { holder?.stop() }
        holder = claimant
    }

    /// Let the speakers go, but only if they are still ours. The previous holder calls its own
    /// `stop()` when a new one takes over, and by then `holder` is already the new one — clearing it
    /// there would leave the playback that is actually sounding unaccounted for.
    static func release(_ claimant: SpeakerClaimant) {
        if holder === claimant { holder = nil }
    }

    /// Whether this object still holds the floor — the check each class made as `Self.current === self`
    /// after an await, to bow out when a later press took the speakers while it was loading.
    static func holds(_ claimant: SpeakerClaimant) -> Bool {
        holder === claimant
    }
}
