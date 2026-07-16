import Testing
@testable import IskraFeatures

/// The one pair of speakers, shared across playback kinds. These pin the behaviour that a voice
/// message and a video note — different classes, one floor — cannot sound at once, which is the
/// thing two independent `static current` fields used to get wrong.
@MainActor
struct SpeakerTests {
    /// Stands in for either an `AudioPlayback` or a `VideoPlayback`: all `Speaker` asks of a holder
    /// is that it can be told to stop, and it records whether it was.
    private final class Claimant: SpeakerClaimant {
        private(set) var stopped = false
        func stop() { stopped = true }
    }

    @Test("claiming stops whoever held the floor before — of either kind")
    func claimStopsPrevious() {
        let voice = Claimant()
        let circle = Claimant()

        Speaker.claim(voice)
        Speaker.claim(circle)

        #expect(voice.stopped)
        #expect(Speaker.holds(circle))
        #expect(!Speaker.holds(voice))

        Speaker.release(circle)
    }

    @Test("claiming the floor you already hold does not stop you")
    func reclaimingSelfDoesNotStop() {
        let voice = Claimant()

        Speaker.claim(voice)
        Speaker.claim(voice)

        // The resume path depends on this: a paused message is still the holder, and stopping it to
        // start it would nil its player and rewind, so resuming would silently do nothing.
        #expect(!voice.stopped)
        #expect(Speaker.holds(voice))

        Speaker.release(voice)
    }

    @Test("releasing frees the floor only if you are still the one holding it")
    func releaseIsGuardedByIdentity() {
        let first = Claimant()
        let second = Claimant()

        Speaker.claim(first)
        Speaker.claim(second)

        // `first.stop()` runs when `second` takes over; by then the floor is `second`. `first`
        // releasing now must not clear it, or the playback actually sounding goes unaccounted for.
        Speaker.release(first)
        #expect(Speaker.holds(second))

        Speaker.release(second)
        #expect(!Speaker.holds(second))
    }
}
