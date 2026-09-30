import Foundation
import Testing
@testable import IskraCore

/// The two switches about generated faces, which are the only preferences in this app that two
/// processes read.
///
/// Everything pinned here failed silently once it was wrong: a flag the extension cannot see makes
/// a lock screen that disagrees with the chat list, and neither one says why.
@Suite("BetaFeatures")
struct BetaFeaturesTests {
    /// A throwaway defaults, one per test — these run in parallel, and the real App Group is the
    /// user's own.
    private func freshDefaults(_ name: String) throws -> UserDefaults {
        let suite = "iskra.tests.betaFeatures.\(name)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    /// The shipped answer, on defaults nobody has written to: a creature where there is no
    /// picture, and never over one there is.
    ///
    /// This test used to pin the opposite — the feature was off until asked for — and the change
    /// is deliberate rather than a drift: initials are not a neutral default, they are the absence
    /// of a face, and most people in most rooms have never set a picture. What must not change is
    /// the second line. A default that drew over a photograph somebody chose would be the app
    /// overruling them, and that stays behind a switch.
    @Test("by default a creature stands in for a missing picture, and only for that")
    func onByDefault() throws {
        let defaults = try freshDefaults("default")
        #expect(BetaFeatures.drawsGeneratedFace(hasPicture: false, in: defaults))
        #expect(BetaFeatures.drawsGeneratedFace(hasPicture: true, in: defaults) == false)
    }

    /// And turning it off is still turning it off — the value written by hand beats the default,
    /// which is the whole of what a default is.
    @Test("switched off, nobody gets a creature")
    func offWhenAsked() throws {
        let defaults = try freshDefaults("off")
        defaults.set(false, forKey: BetaFeatures.blobatarKey)

        #expect(BetaFeatures.drawsGeneratedFace(hasPicture: false, in: defaults) == false)
        #expect(BetaFeatures.drawsGeneratedFace(hasPicture: true, in: defaults) == false)
    }

    /// The ordinary case: a face where there is none, and the photograph left alone where there is.
    @Test("on, a creature stands in only where there is no picture")
    func standsInForMissingPictures() throws {
        let defaults = try freshDefaults("on")
        defaults.set(true, forKey: BetaFeatures.blobatarKey)

        #expect(BetaFeatures.drawsGeneratedFace(hasPicture: false, in: defaults))
        #expect(BetaFeatures.drawsGeneratedFace(hasPicture: true, in: defaults) == false)
    }

    @Test("forced, a creature wins even against a picture")
    func forcedBeatsAPicture() throws {
        let defaults = try freshDefaults("forced")
        defaults.set(true, forKey: BetaFeatures.blobatarKey)
        defaults.set(true, forKey: BetaFeatures.forceBlobatarKey)

        #expect(BetaFeatures.drawsGeneratedFace(hasPicture: true, in: defaults))
    }

    /// Forcing something that is switched off is not a way to switch it on. The screen hides the
    /// second toggle unless the first is on, so this state is only reachable by an old value left
    /// behind — which is exactly when a rule like this earns its keep.
    @Test("forced means nothing while the feature is off")
    func forcedIsMeaninglessWhenOff() throws {
        let defaults = try freshDefaults("forcedOff")
        // Both written by hand: creatures are on by default now, so the state this test is about
        // — forced, over a feature that is off — is only reachable by saying so.
        defaults.set(false, forKey: BetaFeatures.blobatarKey)
        defaults.set(true, forKey: BetaFeatures.forceBlobatarKey)

        #expect(BetaFeatures.drawsGeneratedFace(hasPicture: false, in: defaults) == false)
    }

    @Test("a flag set before the move is carried across, once")
    func adoptsTheOldValue() throws {
        let local = try freshDefaults("adopt.local")
        let shared = try freshDefaults("adopt.shared")
        local.set(true, forKey: BetaFeatures.blobatarKey)

        BetaFeatures.adoptFaceFlags(from: local, into: shared)
        #expect(shared.bool(forKey: BetaFeatures.blobatarKey))

        // And turning it off afterwards must stick: the value it used to have is not an opinion
        // any more, and a migration that runs at every launch would keep reinstating it.
        shared.set(false, forKey: BetaFeatures.blobatarKey)
        BetaFeatures.adoptFaceFlags(from: local, into: shared)
        #expect(shared.bool(forKey: BetaFeatures.blobatarKey) == false)
    }

    @Test("nothing to carry is nothing to write")
    func adoptsNothingFromAnEmptyStore() throws {
        let local = try freshDefaults("adopt.empty.local")
        let shared = try freshDefaults("adopt.empty.shared")

        BetaFeatures.adoptFaceFlags(from: local, into: shared)
        #expect(shared.object(forKey: BetaFeatures.blobatarKey) == nil)
    }
}
