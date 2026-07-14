import Testing
import Foundation
import AVFoundation
@testable import IskraCore

/// What a file that is not really a video does to the app that is asked to send it.
///
/// `UInt64(someDouble)` **traps**. Not an optional and not a clamp — it takes the process down
/// with "Double value cannot be converted to UInt64 because it is either infinite or NaN". And the
/// double came out of `AVFoundation`, computed from a size and a transform read from a file the
/// *user chose* in a picker. So a corrupt clip, or one whose track claims an indefinite duration,
/// did not fail to send. It crashed the app, on the ordinary path of forwarding something somebody
/// had sent you.
///
/// These pin the conversions themselves, which is the only part that can be tested without a
/// broken file to hand: the rule is "a number this is not, or a number this cannot be, comes back
/// as nothing" — and nothing is a shape hint the event can perfectly well do without.
@Suite
struct MediaMetadataTests {
    @Test("a size that is not a number is not a size")
    func nonNumericSizeIsRefused() {
        #expect(MediaMetadata.pixels(.nan) == nil)
        #expect(MediaMetadata.pixels(.infinity) == nil)
        #expect(MediaMetadata.pixels(-1) == nil)
    }

    @Test("an ordinary size survives untouched")
    func ordinarySizeSurvives() {
        #expect(MediaMetadata.pixels(1080) == 1080)
        #expect(MediaMetadata.pixels(0) == 0)
    }

    /// `CMTimeGetSeconds` answers NaN for an indefinite time and infinity for an unknown one. Both
    /// are ordinary things to say about a *stream*; neither is a thing to say about a file, which
    /// is what this is ever asked about.
    @Test("a duration that is not a number is not a duration")
    func nonNumericDurationIsRefused() {
        #expect(MediaMetadata.seconds(.nan) == nil)
        #expect(MediaMetadata.seconds(.infinity) == nil)
        #expect(MediaMetadata.seconds(-1) == nil)
    }

    @Test("an ordinary duration survives untouched")
    func ordinaryDurationSurvives() {
        #expect(MediaMetadata.seconds(12.5) == 12.5)
    }

    /// The other half of the same class of bug, one file over: a track claiming no size at all
    /// makes `side / edge` infinite, and an infinite scale goes into a `CGAffineTransform` without
    /// a word of complaint and comes out as an export nobody can play.
    @Test("a video with no size in it is refused rather than exported into nonsense")
    func squareRefusesASizelessTrack() async throws {
        // A file that is not a video at all: no tracks, therefore no size.
        let url = URL.temporaryDirectory.appending(component: "\(UUID().uuidString).mov")
        try Data("this is not a video".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        await #expect(throws: (any Error).self) {
            try await SquareVideoExporter.square(url)
        }
    }
}
