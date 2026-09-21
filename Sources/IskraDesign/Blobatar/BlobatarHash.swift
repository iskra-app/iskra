//  Ported from blobatar (https://blobatar.dev), MIT licence,
//  Copyright (c) 2026 Alain. See Licenses/blobatar.txt.

import Foundation

/// The seed hash.
///
/// Two properties are the whole reason this is not `hashValue` or SHA-256:
///
/// - *Avalanche.* "boris" and "borys" have to come out as visibly different creatures, not as
///   two shades of the same one. A plain FNV-1a mixing loop does not give that; murmur3's
///   finalizer does, and blobatar uses one feeding the other.
/// - *Streaming.* The seed is hashed once, and every trait continues from that state with its
///   own name mixed in. So traits are independent: a trait added later cannot disturb a face
///   that already exists.
///
/// It is reproduced here exactly — including the parts that look like accidents, because they
/// are load-bearing for compatibility. `state(_:)` mixes in the string's length, and in
/// JavaScript that is the **UTF-16** count while the bytes fed straight afterwards are
/// **UTF-8**; a seed with an emoji in it hashes differently if you "fix" that. A Matrix user ID
/// is ASCII, so the two agree for the seeds this app actually uses — but the golden fixture is
/// full of "🦊6🌱", and it is the fixture that says whether this port is the same program.
enum BlobatarHash {
    /// Mixes bytes into a 32-bit state: FNV-1a's xor-then-multiply shape, murmur3's `c1` as the
    /// multiplier, and a 13-bit rotate that plain FNV-1a does not have.
    private static func feed(_ state: UInt32, _ bytes: some Sequence<UInt8>) -> UInt32 {
        var h = state
        for byte in bytes {
            h = (h ^ UInt32(byte)) &* 3_432_918_353
            h = (h << 13) | (h >> 19)
        }
        return h
    }

    /// murmur3's `fmix32` — a bijection on `UInt32` with full avalanche.
    private static func finalize(_ state: UInt32) -> UInt32 {
        var h = state
        h = (h ^ (h >> 16)) &* 2_246_822_507
        h = (h ^ (h >> 13)) &* 3_266_489_909
        return h ^ (h >> 16)
    }

    /// NFC, then trim, then lowercase — in that order.
    ///
    /// So that two spellings a person considers the same hash the same: a precomposed "é" and a
    /// decomposed one, `@Boris:matrix.org` and `@boris:matrix.org`, a name pasted with a space
    /// on the end.
    static func normalize(_ seed: String) -> String {
        seed.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    /// Hashes the seed once into a state every trait then continues from.
    static func state(_ seed: String, normalize shouldNormalize: Bool = true) -> UInt32 {
        let s = shouldNormalize ? normalize(seed) : seed
        // `utf16.count`, not `utf8.count` and not `count`. See the note above.
        return feed(1_779_033_703 ^ UInt32(truncatingIfNeeded: s.utf16.count), Array(s.utf8))
    }

    /// One uniform value in `[0, 1)` for `key`, independent of every other key.
    static func stream(_ state: UInt32, _ key: String) -> Double {
        let separated = feed(state, CollectionOfOne(UInt8(0xFF)))
        return Double(finalize(feed(separated, Array(key.utf8)))) / 4_294_967_296
    }
}
