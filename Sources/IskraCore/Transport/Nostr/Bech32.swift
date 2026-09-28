import Foundation

/// Bech32, for the one thing this app needs it for: reading an `npub1…`.
///
/// A bridge prints its key as hex, and hex is what the protocol carries — but `npub` is how a
/// nostr key is written down everywhere else, so it is what a person is most likely to paste into
/// the settings field. Both are accepted; the checksum is what makes accepting `npub` safe, since
/// a key with a typo in it fails here instead of becoming a bridge that never answers.
///
/// This is BIP-173 bech32, not bech32m: NIP-19 uses the original constant.
enum Bech32 {
    private static let alphabet = Array("qpzry9x8gf2tvdw0s3jn54khce6mua7l")

    struct Decoded {
        /// `npub`, `nsec`, `note`…
        var prefix: String
        /// The data part, already converted from 5-bit groups back to bytes.
        var bytes: Data
    }

    static func decode(_ string: String) -> Decoded? {
        let lowercased = string.lowercased()
        // Mixed case is invalid rather than merely untidy: the checksum is defined over one case.
        guard lowercased == string || string.uppercased() == string else { return nil }
        guard let separator = lowercased.lastIndex(of: "1"), lowercased.count <= 2_000 else { return nil }

        let prefix = String(lowercased[lowercased.startIndex..<separator])
        let payload = Array(lowercased[lowercased.index(after: separator)...])
        guard !prefix.isEmpty, payload.count >= 6 else { return nil }

        var values = [UInt8]()
        for character in payload {
            guard let index = alphabet.firstIndex(of: character) else { return nil }
            values.append(UInt8(index))
        }
        guard verifyChecksum(prefix: prefix, values: values) else { return nil }
        guard let bytes = convert(Array(values.dropLast(6)), from: 5, to: 8, pad: false) else { return nil }
        return Decoded(prefix: prefix, bytes: Data(bytes))
    }

    static func encode(prefix: String, bytes: Data) -> String? {
        guard let values = convert([UInt8](bytes), from: 8, to: 5, pad: true) else { return nil }
        let checksum = createChecksum(prefix: prefix, values: values)
        let payload = (values + checksum).map { String(alphabet[Int($0)]) }.joined()
        return prefix + "1" + payload
    }

    // MARK: - The arithmetic, straight from BIP-173

    private static func polymod(_ values: [UInt8]) -> UInt32 {
        let generator: [UInt32] = [0x3b6a_57b2, 0x2650_8e6d, 0x1ea1_19fa, 0x3d42_33dd, 0x2a14_62b3]
        var checksum: UInt32 = 1
        for value in values {
            let top = checksum >> 25
            checksum = (checksum & 0x1ff_ffff) << 5 ^ UInt32(value)
            for index in 0..<5 where (top >> UInt32(index)) & 1 == 1 {
                checksum ^= generator[index]
            }
        }
        return checksum
    }

    private static func expand(_ prefix: String) -> [UInt8] {
        let bytes = Array(prefix.utf8)
        return bytes.map { $0 >> 5 } + [0] + bytes.map { $0 & 31 }
    }

    private static func verifyChecksum(prefix: String, values: [UInt8]) -> Bool {
        polymod(expand(prefix) + values) == 1
    }

    private static func createChecksum(prefix: String, values: [UInt8]) -> [UInt8] {
        let enhanced = expand(prefix) + values + [0, 0, 0, 0, 0, 0]
        let mod = polymod(enhanced) ^ 1
        return (0..<6).map { UInt8((mod >> (5 * (5 - UInt32($0)))) & 31) }
    }

    /// Regroup bits — 8-bit bytes to 5-bit groups on the way in, and back on the way out.
    private static func convert(_ input: [UInt8], from: UInt32, to: UInt32, pad: Bool) -> [UInt8]? {
        var accumulator: UInt32 = 0
        var bits: UInt32 = 0
        var out = [UInt8]()
        let maximum: UInt32 = (1 << to) - 1

        for value in input {
            accumulator = (accumulator << from) | UInt32(value)
            bits += from
            while bits >= to {
                bits -= to
                out.append(UInt8((accumulator >> bits) & maximum))
            }
        }
        if pad {
            if bits > 0 { out.append(UInt8((accumulator << (to - bits)) & maximum)) }
        } else if bits >= from || ((accumulator << (to - bits)) & maximum) != 0 {
            // Leftover bits that are not zero mean the encoding was not produced by this scheme.
            return nil
        }
        return out
    }
}
