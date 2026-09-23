import Foundation

/// ChaCha20 as RFC 8439 defines it: the stream cipher on its own, with no authentication.
///
/// This is the one piece of cryptography in the app that is written out here rather than called,
/// and it is worth being plain about why, because the rule elsewhere is the opposite — Matrix's
/// cryptography is the Rust SDK's and none of it is reimplemented.
///
/// NIP-44 v2 is built from three primitives: an ECDH on secp256k1, HKDF-SHA256, and *unauthenticated*
/// ChaCha20 with its own HMAC over the ciphertext. CryptoKit has the middle one and offers
/// `ChaChaPoly` for the last — but ChaChaPoly is the AEAD, which appends its own Poly1305 tag and
/// will not hand back a raw keystream. There is no way to reach the bare cipher through it, and
/// substituting the AEAD would produce a payload no other nostr client could read. libsecp256k1
/// covers the curve; this covers the twenty lines CryptoKit declines to expose.
///
/// It is held to RFC 8439's own test vectors *and* to the NIP-44 vector file, which exercises it
/// through every encryption in the suite — so a mistake here fails loudly in the tests rather than
/// quietly on the wire.
enum ChaCha20 {
    /// XOR `data` with the keystream for `key`/`nonce`, starting at `counter`.
    ///
    /// Encryption and decryption are the same operation, which is why there is one function.
    /// NIP-44 starts the counter at zero.
    static func apply(_ data: Data, key: Data, nonce: Data, counter: UInt32 = 0) -> Data {
        precondition(key.count == 32, "ChaCha20 takes a 256-bit key")
        precondition(nonce.count == 12, "ChaCha20 takes a 96-bit nonce")

        let keyWords = words(of: key)
        let nonceWords = words(of: nonce)
        var out = Data(capacity: data.count)
        var block = counter
        var offset = 0

        let input = [UInt8](data)
        while offset < input.count {
            let keystream = self.block(key: keyWords, nonce: nonceWords, counter: block)
            let take = min(64, input.count - offset)
            for i in 0..<take {
                out.append(input[offset + i] ^ keystream[i])
            }
            offset += take
            block &+= 1
        }
        return out
    }

    /// One 64-byte block of keystream.
    private static func block(key: [UInt32], nonce: [UInt32], counter: UInt32) -> [UInt8] {
        // "expand 32-byte k", the constant every ChaCha20 state starts with.
        var state: [UInt32] = [0x6170_7865, 0x3320_646E, 0x7962_2D32, 0x6B20_6574]
        state.append(contentsOf: key)
        state.append(counter)
        state.append(contentsOf: nonce)

        var working = state
        for _ in 0..<10 {
            // Columns, then diagonals: the two halves of a ChaCha double round.
            quarterRound(&working, 0, 4, 8, 12)
            quarterRound(&working, 1, 5, 9, 13)
            quarterRound(&working, 2, 6, 10, 14)
            quarterRound(&working, 3, 7, 11, 15)
            quarterRound(&working, 0, 5, 10, 15)
            quarterRound(&working, 1, 6, 11, 12)
            quarterRound(&working, 2, 7, 8, 13)
            quarterRound(&working, 3, 4, 9, 14)
        }

        var out = [UInt8]()
        out.reserveCapacity(64)
        for i in 0..<16 {
            let word = working[i] &+ state[i]
            out.append(UInt8(truncatingIfNeeded: word))
            out.append(UInt8(truncatingIfNeeded: word >> 8))
            out.append(UInt8(truncatingIfNeeded: word >> 16))
            out.append(UInt8(truncatingIfNeeded: word >> 24))
        }
        return out
    }

    private static func quarterRound(_ s: inout [UInt32], _ a: Int, _ b: Int, _ c: Int, _ d: Int) {
        s[a] = s[a] &+ s[b]; s[d] = rotate(s[d] ^ s[a], 16)
        s[c] = s[c] &+ s[d]; s[b] = rotate(s[b] ^ s[c], 12)
        s[a] = s[a] &+ s[b]; s[d] = rotate(s[d] ^ s[a], 8)
        s[c] = s[c] &+ s[d]; s[b] = rotate(s[b] ^ s[c], 7)
    }

    private static func rotate(_ value: UInt32, _ by: UInt32) -> UInt32 {
        (value << by) | (value >> (32 - by))
    }

    /// Little-endian, which is what ChaCha20 reads its key and nonce as.
    private static func words(of data: Data) -> [UInt32] {
        stride(from: 0, to: data.count, by: 4).map { index in
            let bytes = Array(data[data.startIndex + index..<data.startIndex + index + 4])
            return UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
        }
    }
}
