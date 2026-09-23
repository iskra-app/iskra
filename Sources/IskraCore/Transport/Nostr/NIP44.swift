import CryptoKit
import Foundation
import Security
import secp256k1

/// NIP-44 v2 — the encryption both ends of the tunnel speak.
///
/// The bridge calls `nostr`'s Rust implementation; this is the same algorithm on this side, and
/// "the same" is not a matter of opinion: the official vector file
/// (`Tests/IskraCoreTests/Resources/nip44.vectors.json`, published with the NIP) is run against
/// this code, every case of it, including the 65535-byte message. An implementation that agrees
/// with those vectors agrees with the bridge.
///
/// The shape of it: the conversation key is ECDH(ours, theirs), so both sides derive the same
/// secret from opposite halves and nothing key-shaped is ever put on the wire. Per message, a
/// random 32-byte nonce expands that into a ChaCha20 key, a ChaCha20 nonce and an HMAC key; the
/// plaintext is padded to a power-of-two-ish length so that the ciphertext's size says as little
/// as possible about the message; and the MAC covers the nonce as well as the ciphertext.
enum NIP44 {
    enum Failure: Error, Equatable {
        /// The secret or public key is not a point on the curve.
        case badKey
        /// Nothing to encrypt, or more than the format can carry.
        case badPlaintextLength(Int)
        /// The payload is not something this version of NIP-44 produced.
        case malformedPayload(String)
        /// The MAC does not match: wrong key, or the ciphertext was altered in flight.
        case wrongKeyOrTampered
        /// The system would not give us a nonce, and one must never be invented.
        case noRandomness
    }

    static let version: UInt8 = 2

    // MARK: - Conversation key

    /// ECDH between our secret and their public key, hardened by HKDF-extract.
    ///
    /// `theirPublicKey` is the 32-byte x-only key nostr writes everywhere. The y coordinate is
    /// conventionally taken as even — that is the convention every nostr implementation shares,
    /// and it is what makes an x-only key enough to talk to somebody.
    static func conversationKey(ourSecret: Data, theirPublicKey: Data) throws -> Data {
        guard ourSecret.count == 32, theirPublicKey.count == 32 else { throw Failure.badKey }

        let secret: secp256k1.KeyAgreement.PrivateKey
        let publicKey: secp256k1.KeyAgreement.PublicKey
        do {
            secret = try secp256k1.KeyAgreement.PrivateKey(rawRepresentation: ourSecret)
            publicKey = try secp256k1.KeyAgreement.PublicKey(
                rawRepresentation: Data([0x02]) + theirPublicKey, format: .compressed)
        } catch {
            throw Failure.badKey
        }

        // libsecp256k1 hashes the shared point by default (SHA256 of the compressed form). NIP-44
        // wants the bare x coordinate, so the hash function is replaced by one that copies it out.
        let shared = try? secret.sharedSecretFromKeyAgreement(with: publicKey) { output, x32, _, _ in
            guard let output, let x32 else { return 0 }
            output.update(from: x32, count: 32)
            return 1
        }
        guard let shared else { throw Failure.badKey }
        let x = shared.withUnsafeBytes { Data($0) }

        let key = HKDF<CryptoKit.SHA256>.extract(inputKeyMaterial: SymmetricKey(data: x),
                                                 salt: Data("nip44-v2".utf8))
        return key.withUnsafeBytes { Data($0) }
    }

    // MARK: - Messages

    /// Encrypt, and return the base64 payload that goes in an event's `content`.
    ///
    /// The nonce is given only by the tests, which need a fixed one to compare a payload against
    /// the vector file. Everywhere else it comes from the system.
    static func encrypt(_ plaintext: Data, conversationKey: Data, nonce: Data? = nil) throws -> String {
        guard (1...65_535).contains(plaintext.count) else {
            throw Failure.badPlaintextLength(plaintext.count)
        }
        let nonce = try nonce ?? randomNonce()
        let keys = try messageKeys(conversationKey: conversationKey, nonce: nonce)
        let ciphertext = ChaCha20.apply(pad(plaintext), key: keys.chachaKey, nonce: keys.chachaNonce)
        let mac = authenticate(ciphertext, key: keys.hmacKey, aad: nonce)
        return (Data([version]) + nonce + ciphertext + mac).base64EncodedString()
    }

    /// Decrypt a payload from somebody who has the same conversation key.
    ///
    /// Anyone on a relay can publish an event addressed to us, so failure here is ordinary rather
    /// than exceptional — it means "not for us", and the caller drops it without a word.
    static func decrypt(_ payload: String, conversationKey: Data) throws -> Data {
        // A payload that begins with `#` is NIP-44 saying "some future version, not this one". It
        // is called out by the spec, and by the vector file, as its own case.
        guard !payload.hasPrefix("#") else { throw Failure.malformedPayload("unknown future version") }
        guard (132...87_472).contains(payload.utf8.count),
              let raw = Data(base64Encoded: payload),
              (99...65_603).contains(raw.count)
        else { throw Failure.malformedPayload("not a v2 payload") }
        guard raw[raw.startIndex] == version else {
            throw Failure.malformedPayload("unknown version \(raw[raw.startIndex])")
        }

        let nonce = raw.subdata(in: 1..<33)
        let ciphertext = raw.subdata(in: 33..<(raw.count - 32))
        let mac = raw.subdata(in: (raw.count - 32)..<raw.count)

        let keys = try messageKeys(conversationKey: conversationKey, nonce: nonce)
        guard constantTimeEquals(authenticate(ciphertext, key: keys.hmacKey, aad: nonce), mac) else {
            throw Failure.wrongKeyOrTampered
        }

        let padded = ChaCha20.apply(ciphertext, key: keys.chachaKey, nonce: keys.chachaNonce)
        guard padded.count >= 2 else { throw Failure.malformedPayload("padding is truncated") }
        let length = Int(padded[padded.startIndex]) << 8 | Int(padded[padded.startIndex + 1])
        guard length > 0, padded.count == 2 + paddedLength(of: length) else {
            throw Failure.malformedPayload("padding does not match the length it declares")
        }
        return padded.subdata(in: 2..<(2 + length))
    }

    // MARK: - The parts

    struct MessageKeys {
        var chachaKey: Data
        var chachaNonce: Data
        var hmacKey: Data
    }

    /// 76 bytes of HKDF output, cut into the three keys one message uses.
    static func messageKeys(conversationKey: Data, nonce: Data) throws -> MessageKeys {
        guard conversationKey.count == 32, nonce.count == 32 else { throw Failure.badKey }
        let expanded = HKDF<CryptoKit.SHA256>.expand(pseudoRandomKey: SymmetricKey(data: conversationKey),
                                                     info: nonce,
                                                     outputByteCount: 76)
        let bytes = expanded.withUnsafeBytes { Data($0) }
        return MessageKeys(chachaKey: bytes.subdata(in: 0..<32),
                           chachaNonce: bytes.subdata(in: 32..<44),
                           hmacKey: bytes.subdata(in: 44..<76))
    }

    /// How long a message of `length` bytes becomes once padded.
    ///
    /// Sizes climb in powers of two and then in eighths of one, so that the length of a ciphertext
    /// narrows a message down to a bracket rather than to a number of characters.
    static func paddedLength(of length: Int) -> Int {
        guard length > 32 else { return 32 }
        let nextPower = 1 << (Int(log2(Double(length - 1))) + 1)
        let chunk = nextPower <= 256 ? 32 : nextPower / 8
        return chunk * (((length - 1) / chunk) + 1)
    }

    private static func pad(_ plaintext: Data) -> Data {
        var padded = Data([UInt8(truncatingIfNeeded: plaintext.count >> 8),
                           UInt8(truncatingIfNeeded: plaintext.count)])
        padded.append(plaintext)
        padded.append(Data(repeating: 0, count: paddedLength(of: plaintext.count) - plaintext.count))
        return padded
    }

    /// HMAC over the nonce *and* the ciphertext. The nonce is the "additional data": leaving it
    /// out would let somebody move a ciphertext to another nonce and have it still verify.
    private static func authenticate(_ ciphertext: Data, key: Data, aad: Data) -> Data {
        var mac = HMAC<CryptoKit.SHA256>(key: SymmetricKey(data: key))
        mac.update(data: aad)
        mac.update(data: ciphertext)
        return Data(mac.finalize())
    }

    private static func constantTimeEquals(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for (left, right) in zip(lhs, rhs) { difference |= left ^ right }
        return difference == 0
    }

    /// 32 bytes from the system CSPRNG.
    ///
    /// A nonce reused with the same conversation key repeats the keystream, which is the one way
    /// to break this construction from the outside — so it comes from `SecRandomCopyBytes` and
    /// from nowhere else. It **throws** rather than trapping, for the same reason
    /// `SessionStore.randomSecret` does: this can run in the notification extension, where a trap
    /// is a process that vanishes with no notification, no log and nothing to connect it to.
    static func randomNonce() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw Failure.noRandomness }
        return Data(bytes)
    }
}
