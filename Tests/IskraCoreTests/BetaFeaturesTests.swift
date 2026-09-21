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
    private func freshDefaults(_ name: String) -> UserDefaults {
        let suite = "iskra.tests.betaFeatures.\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test("no creature until somebody asks for one")
    func offByDefault() {
        let defaults = freshDefaults("default")
        #expect(BetaFeatures.drawsGeneratedFace(hasPicture: false, in: defaults) == false)
        #expect(BetaFeatures.drawsGeneratedFace(hasPicture: true, in: defaults) == false)
    }

    /// The ordinary case: a face where there is none, and the photograph left alone where there is.
    @Test("on, a creature stands in only where there is no picture")
    func standsInForMissingPictures() {
        let defaults = freshDefaults("on")
        defaults.set(true, forKey: BetaFeatures.blobatarKey)

        #expect(BetaFeatures.drawsGeneratedFace(hasPicture: false, in: defaults))
        #expect(BetaFeatures.drawsGeneratedFace(hasPicture: true, in: defaults) == false)
    }

    @Test("forced, a creature wins even against a picture")
    func forcedBeatsAPicture() {
        let defaults = freshDefaults("forced")
        defaults.set(true, forKey: BetaFeatures.blobatarKey)
        defaults.set(true, forKey: BetaFeatures.forceBlobatarKey)

        #expect(BetaFeatures.drawsGeneratedFace(hasPicture: true, in: defaults))
    }

    /// Forcing something that is switched off is not a way to switch it on. The screen hides the
    /// second toggle unless the first is on, so this state is only reachable by an old value left
    /// behind — which is exactly when a rule like this earns its keep.
    @Test("forced means nothing while the feature is off")
    func forcedIsMeaninglessWhenOff() {
        let defaults = freshDefaults("forcedOff")
        defaults.set(true, forKey: BetaFeatures.forceBlobatarKey)

        #expect(BetaFeatures.drawsGeneratedFace(hasPicture: false, in: defaults) == false)
    }

    @Test("a flag set before the move is carried across, once")
    func adoptsTheOldValue() {
        let local = freshDefaults("adopt.local")
        let shared = freshDefaults("adopt.shared")
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
    func adoptsNothingFromAnEmptyStore() {
        let local = freshDefaults("adopt.empty.local")
        let shared = freshDefaults("adopt.empty.shared")

        BetaFeatures.adoptFaceFlags(from: local, into: shared)
        #expect(shared.object(forKey: BetaFeatures.blobatarKey) == nil)
    }
}
