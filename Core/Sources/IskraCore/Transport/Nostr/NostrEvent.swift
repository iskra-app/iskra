import CryptoKit
import Foundation
import secp256k1

/// One nostr event: the only kind of thing that travels on a relay.
///
/// The id is a hash of the event's own fields, so it cannot be chosen, and the signature is over
/// that hash. Both are computed here rather than trusted from the wire.
struct NostrEvent: Sendable, Equatable {
    var id: String
    var pubkey: String
    var createdAt: Int
    var kind: Int
    var tags: [[String]]
    var content: String
    var sig: String

    /// Build an event and sign it.
    static func signed(kind: Int,
                       content: String,
                       tags: [[String]],
                       createdAt: Int = Int(Date().timeIntervalSince1970),
                       keys: NostrKeypair) throws -> NostrEvent {
        let pubkey = Hex.string(keys.publicKey)
        let serialized = serialize(pubkey: pubkey, createdAt: createdAt, kind: kind,
                                   tags: tags, content: content)
        let id = Data(CryptoKit.SHA256.hash(data: Data(serialized.utf8)))
        let signature = try keys.sign(id)
        return NostrEvent(id: Hex.string(id),
                          pubkey: pubkey,
                          createdAt: createdAt,
                          kind: kind,
                          tags: tags,
                          content: content,
                          sig: Hex.string(signature))
    }

    /// The exact bytes an event id is the hash of.
    ///
    /// Written out by hand, because `JSONSerialization` is free to order dictionary keys as it
    /// likes and to escape characters as it likes — and here both are part of the hash. This is
    /// the array NIP-01 specifies, with no whitespace anywhere and only the six escapes it names.
    static func serialize(pubkey: String, createdAt: Int, kind: Int,
                          tags: [[String]], content: String) -> String {
        let tagsJSON = "[" + tags.map { tag in
            "[" + tag.map { "\"\(escape($0))\"" }.joined(separator: ",") + "]"
        }.joined(separator: ",") + "]"
        return "[0,\"\(pubkey)\",\(createdAt),\(kind),\(tagsJSON),\"\(escape(content))\"]"
    }

    private static func escape(_ string: String) -> String {
        var out = ""
        out.reserveCapacity(string.count)
        for character in string.unicodeScalars {
            switch character {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default: out.unicodeScalars.append(character)
            }
        }
        return out
    }

    // MARK: - On the wire

    var json: [String: Any] {
        ["id": id, "pubkey": pubkey, "created_at": createdAt, "kind": kind,
         "tags": tags, "content": content, "sig": sig]
    }

    init(id: String, pubkey: String, createdAt: Int, kind: Int, tags: [[String]], content: String, sig: String) {
        self.id = id
        self.pubkey = pubkey
        self.createdAt = createdAt
        self.kind = kind
        self.tags = tags
        self.content = content
        self.sig = sig
    }

    init?(json: Any) {
        guard let object = json as? [String: Any],
              let id = object["id"] as? String,
              let pubkey = object["pubkey"] as? String,
              let createdAt = object["created_at"] as? Int,
              let kind = object["kind"] as? Int,
              let content = object["content"] as? String,
              let sig = object["sig"] as? String
        else { return nil }
        self.init(id: id, pubkey: pubkey, createdAt: createdAt, kind: kind,
                  tags: (object["tags"] as? [[String]]) ?? [], content: content, sig: sig)
    }

    /// Whether this event really is from the key it names, with the fields it names.
    ///
    /// Belt and braces: the payload inside is NIP-44, which already cannot be forged by anybody
    /// without the conversation key, so an event that got this far and decrypts is from the
    /// bridge whatever its signature says. The check costs one verification per answer and closes
    /// the gap anyway — a relay that serves us rubbish gets told no here rather than three layers
    /// further in.
    func isAuthentic() -> Bool {
        guard let publicKey = Hex.data(pubkey), publicKey.count == 32,
              let signature = Hex.data(sig), signature.count == 64
        else { return false }

        let serialized = Self.serialize(pubkey: pubkey, createdAt: createdAt, kind: kind,
                                        tags: tags, content: content)
        let serializedBytes = Data(serialized.utf8)
        guard Hex.string(Data(CryptoKit.SHA256.hash(data: serializedBytes))) == id else { return false }

        guard let validating = try? secp256k1.Signing.PublicKey(
            rawRepresentation: Data([0x02]) + publicKey, format: .compressed),
            let parsed = try? secp256k1.Signing.SchnorrSignature(rawRepresentation: signature)
        else { return false }
        // Over the serialized event rather than over the id: this overload hashes what it is
        // given with SHA256, which is precisely how the id was arrived at in the first place.
        return validating.schnorr.isValidSignature(parsed, for: serializedBytes)
    }
}
