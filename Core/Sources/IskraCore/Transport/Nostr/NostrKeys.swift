import CryptoKit
import Foundation
import Security
import secp256k1

/// A nostr keypair: 32 bytes of secret, and the x-only public key everybody addresses.
///
/// The app's own pair is not an identity in any social sense — nobody follows it and it posts
/// nothing. It is the return address on the tunnel, and the thing a closed bridge's
/// `ALLOWED_PUBKEYS` lists. It is kept because it has to be: a key regenerated on each launch
/// would have to be re-added to every private bridge after every restart.
public struct NostrKeypair: Sendable, Equatable {
    /// 32 bytes.
    public let secret: Data
    /// 32 bytes, x-only, which is the only form nostr uses.
    public let publicKey: Data

    public init(secret: Data) throws {
        guard secret.count == 32 else { throw NostrKeyError.notAKey }
        let signing: secp256k1.Signing.PrivateKey
        do {
            signing = try secp256k1.Signing.PrivateKey(rawRepresentation: secret)
        } catch {
            throw NostrKeyError.notAKey
        }
        self.secret = secret
        self.publicKey = Data(signing.publicKey.xonly.bytes)
    }

    public static func generate() throws -> NostrKeypair {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw NostrKeyError.noRandomness }
        return try NostrKeypair(secret: Data(bytes))
    }

    /// A BIP-340 signature over a 32-byte message — for nostr, always an event id.
    func sign(_ message: Data) throws -> Data {
        guard message.count == 32 else { throw NostrKeyError.notAnEventID }
        let signing = try secp256k1.Signing.PrivateKey(rawRepresentation: secret)
        var bytes = [UInt8](message)
        return try signing.schnorr.signature(message: &bytes, auxiliaryRand: nil).rawRepresentation
    }

    /// How this key is written down for a person: `npub1…`.
    public var npub: String {
        Bech32.encode(prefix: "npub", bytes: publicKey) ?? Hex.string(publicKey)
    }
}

public enum NostrKeyError: Error, Equatable {
    case notAKey
    case notAnEventID
    case noRandomness
}

/// Reading the bridge's address out of whatever the user pasted.
///
/// Two spellings are in circulation and both are accepted — bare hex, which is what the bridge
/// prints at startup, and `npub1…`, which is how a nostr key appears everywhere else. An `nsec`
/// is refused on purpose and by name: it is somebody's *secret* key, and a person who pastes one
/// into this field has made a mistake worth telling them about rather than quietly deriving a
/// public key from.
public enum BridgeAddress {
    public enum Problem: Error, Equatable {
        case empty
        case looksLikeASecretKey
        case notAKey
    }

    /// The 32-byte x-only public key, or why it is not one.
    public static func publicKey(from text: String) -> Result<Data, Problem> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.empty) }

        if trimmed.lowercased().hasPrefix("nsec1") { return .failure(.looksLikeASecretKey) }

        if let decoded = Bech32.decode(trimmed), decoded.prefix == "npub", decoded.bytes.count == 32 {
            return .success(decoded.bytes)
        }
        if trimmed.count == 64, let bytes = Hex.data(trimmed) {
            // Hex that parses is still not necessarily a point on the curve, and a key that is not
            // one fails at the first ECDH — a long way from the field it was typed into.
            guard (try? secp256k1.KeyAgreement.PublicKey(
                rawRepresentation: Data([0x02]) + bytes, format: .compressed)) != nil
            else { return .failure(.notAKey) }
            return .success(bytes)
        }
        return .failure(.notAKey)
    }

    /// A key written the way people write one, for showing back what was understood. A bridge's
    /// public key is public by nature — it is what people paste to each other — so this is not a
    /// secret being printed.
    public static func npub(for key: Data) -> String {
        Bech32.encode(prefix: "npub", bytes: key) ?? Hex.string(key)
    }

    public static func isValid(_ text: String) -> Bool {
        if case .success = publicKey(from: text) { return true }
        return false
    }
}
