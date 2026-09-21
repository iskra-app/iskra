//  Ported from blobatar (https://blobatar.dev), MIT licence,
//  Copyright (c) 2026 Alain. See Licenses/blobatar.txt.

import Foundation

/// Reads one creature's traits out of a seed.
///
/// Every value is addressed by a *name* — `"eye.gap"`, `"body.r3"` — rather than pulled off a
/// sequential stream, and that is the design rather than a convenience. Trait names are an
/// append-only namespace: a trait introduced later reads its own independent value and leaves
/// every face that already exists exactly as it was.
///
/// What is *not* free to change is the numeric range a name is read into. `num("eye.gap", 0.1,
/// 0.24)` is part of the seed-to-look mapping, frozen for as long as the faces are meant to stay
/// the same faces.
struct BlobatarTraits {
    private let state: UInt32
    /// Fixed positions in `[0, 1)` for named traits, in the same units the hash would have
    /// produced. A list means "any of these, whichever this seed comes out as" — the key's own
    /// hash spends itself on the index instead of on the value, so a narrowed trait keeps every
    /// property an open one had. An empty list is the same as not configuring the key at all.
    private let overrides: [String: [Double]]

    init(seed: String, normalize: Bool = true, overrides: [String: [Double]] = [:]) {
        self.state = BlobatarHash.state(seed, normalize: normalize)
        self.overrides = overrides
    }

    /// Uniform in `[0, 1)`.
    func callAsFunction(_ key: String) -> Double {
        guard let options = overrides[key], !options.isEmpty else {
            return BlobatarHash.stream(state, key)
        }
        let chosen = options[Int(BlobatarHash.stream(state, key) * Double(options.count))]
        // Clamped rather than trusted: `int` floors, so a configured 1 lands one past the top of
        // its range, and a NaN falls to the bottom through the same comparison — a stack of NaNs
        // in the path data is not a face.
        guard chosen > 0 else { return 0 }
        return chosen < 1 ? chosen : 0.999999
    }

    /// Uniform in `[min, max)`.
    func num(_ key: String, _ min: Double, _ max: Double) -> Double {
        min + self(key) * (max - min)
    }

    /// Uniform integer in `[min, max]`.
    func int(_ key: String, _ min: Int, _ max: Int) -> Int {
        min + Int(self(key) * Double(max - min + 1))
    }

    /// Symmetric jitter in `[-amount, amount)`.
    func jitter(_ key: String, _ amount: Double) -> Double {
        (self(key) * 2 - 1) * amount
    }
}
