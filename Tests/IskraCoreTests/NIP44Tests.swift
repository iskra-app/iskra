import CryptoKit
import Foundation
import Testing
@testable import IskraCore

/// NIP-44 v2, held to the vector file published with the NIP itself.
///
/// This is the same idea as the blobatar fixture: the encryption is only worth anything if it is
/// *the same* encryption the other end speaks, and "the same" is a thing a file can decide. Every
/// case in `nip44.vectors.json` runs here — conversation keys, the three message keys, padding,
/// whole payloads with a fixed nonce, the 65535-byte message, and the invalid cases that must be
/// refused rather than muddled through.
///
/// The bridge calls `nostr`'s Rust implementation, which is held to the same file. If both agree
/// with it they agree with each other, and no live test is needed to find that out.
struct NIP44Tests {
    // MARK: - The file

    struct Vectors: Decodable {
        struct Root: Decodable { let v2: Version2 }
        struct Version2: Decodable { let valid: Valid; let invalid: Invalid }

        struct Valid: Decodable {
            let getConversationKey: [ConversationKey]
            let getMessageKeys: MessageKeyGroup
            let calcPaddedLen: [[Int]]
            let encryptDecrypt: [EncryptDecrypt]
            let encryptDecryptLongMsg: [LongMessage]
        }

        struct Invalid: Decodable {
            let encryptMsgLengths: [Int]
            let getConversationKey: [ConversationKey]
            let decrypt: [BadPayload]
        }

        struct ConversationKey: Decodable {
            let sec1: String
            let pub2: String
            let conversationKey: String?
        }

        struct MessageKeyGroup: Decodable {
            let conversationKey: String
            let keys: [MessageKey]
        }

        struct MessageKey: Decodable {
            let nonce: String
            let chachaKey: String
            let chachaNonce: String
            let hmacKey: String
        }

        struct EncryptDecrypt: Decodable {
            let sec1: String
            let sec2: String
            let conversationKey: String
            let nonce: String
            let plaintext: String
            let payload: String
        }

        struct LongMessage: Decodable {
            let conversationKey: String
            let nonce: String
            let pattern: String
            let `repeat`: Int
            let plaintextSha256: String
            let payloadSha256: String
        }

        struct BadPayload: Decodable {
            let conversationKey: String
            let nonce: String
            let plaintext: String
            let payload: String
            let note: String
        }
    }

    /// The file is snake_case, as the NIP publishes it; the names here are Swift's.
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    static let vectors: Vectors.Version2 = {
        guard let url = Bundle.module.url(forResource: "nip44.vectors", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let root = try? Self.decoder.decode(Vectors.Root.self, from: data)
        else { fatalError("the NIP-44 vector file is missing from the test bundle") }
        return root.v2
    }()

    static func bytes(_ hex: String) throws -> Data { try #require(Hex.data(hex)) }

    // MARK: - Valid

    @Test func conversationKeysMatchTheVectors() throws {
        for vector in Self.vectors.valid.getConversationKey {
            let key = try NIP44.conversationKey(ourSecret: Self.bytes(vector.sec1),
                                                theirPublicKey: Self.bytes(vector.pub2))
            #expect(Hex.string(key) == vector.conversationKey)
        }
    }

    @Test func messageKeysMatchTheVectors() throws {
        let conversation = try Self.bytes(Self.vectors.valid.getMessageKeys.conversationKey)
        for vector in Self.vectors.valid.getMessageKeys.keys {
            let keys = try NIP44.messageKeys(conversationKey: conversation,
                                             nonce: Self.bytes(vector.nonce))
            #expect(Hex.string(keys.chachaKey) == vector.chachaKey)
            #expect(Hex.string(keys.chachaNonce) == vector.chachaNonce)
            #expect(Hex.string(keys.hmacKey) == vector.hmacKey)
        }
    }

    @Test func paddingClimbsInTheStepsTheSpecSays() throws {
        for pair in Self.vectors.valid.calcPaddedLen {
            #expect(NIP44.paddedLength(of: pair[0]) == pair[1])
        }
    }

    /// The whole thing, both ways, with the nonce pinned so the payload is reproducible byte for
    /// byte — which is the only way a vector file can check an encryption at all.
    @Test func payloadsMatchByteForByte() throws {
        for vector in Self.vectors.valid.encryptDecrypt {
            let conversation = try NIP44.conversationKey(
                ourSecret: Self.bytes(vector.sec1),
                theirPublicKey: try NostrKeypair(secret: Self.bytes(vector.sec2)).publicKey)
            #expect(Hex.string(conversation) == vector.conversationKey)

            let sealed = try NIP44.encrypt(Data(vector.plaintext.utf8),
                                           conversationKey: conversation,
                                           nonce: Self.bytes(vector.nonce))
            #expect(sealed == vector.payload)

            let opened = try NIP44.decrypt(vector.payload, conversationKey: conversation)
            #expect(String(bytes: opened, encoding: .utf8) == vector.plaintext)
        }
    }

    /// Up to 65535 bytes, which is where NIP-44 stops. The chunk budget on both sides of the
    /// tunnel is derived from this number, so a message of exactly this length is not a curiosity.
    @Test func longMessagesSurvive() throws {
        for vector in Self.vectors.valid.encryptDecryptLongMsg {
            let plaintext = String(repeating: vector.pattern, count: vector.repeat)
            let conversation = try Self.bytes(vector.conversationKey)
            let sealed = try NIP44.encrypt(Data(plaintext.utf8),
                                           conversationKey: conversation,
                                           nonce: Self.bytes(vector.nonce))
            #expect(sha256Hex(Data(sealed.utf8)) == vector.payloadSha256)

            let opened = try NIP44.decrypt(sealed, conversationKey: conversation)
            #expect(sha256Hex(opened) == vector.plaintextSha256)
        }
    }

    // MARK: - Invalid

    @Test func emptyAndOversizedMessagesAreRefused() throws {
        let conversation = try Self.bytes(Self.vectors.valid.getMessageKeys.conversationKey)
        for length in Self.vectors.invalid.encryptMsgLengths {
            #expect(throws: NIP44.Failure.badPlaintextLength(length)) {
                try NIP44.encrypt(Data(repeating: 0x61, count: length), conversationKey: conversation)
            }
        }
    }

    @Test func keysOffTheCurveAreRefused() throws {
        for vector in Self.vectors.invalid.getConversationKey {
            #expect(throws: NIP44.Failure.self) {
                try NIP44.conversationKey(ourSecret: Self.bytes(vector.sec1),
                                          theirPublicKey: Self.bytes(vector.pub2))
            }
        }
    }

    /// Tampered payloads, wrong keys, invalid base64, unknown versions. Every one of them is an
    /// error and not a plaintext — a decryption that "mostly worked" is the failure mode this
    /// whole section exists to rule out.
    @Test func badPayloadsAreRefused() throws {
        for vector in Self.vectors.invalid.decrypt {
            #expect(throws: NIP44.Failure.self) {
                try NIP44.decrypt(vector.payload, conversationKey: Self.bytes(vector.conversationKey))
            }
        }
    }

    // MARK: - Our own round trip

    @Test func twoKeypairsArriveAtTheSameConversationKey() throws {
        let client = try NostrKeypair.generate()
        let bridge = try NostrKeypair.generate()

        let ours = try NIP44.conversationKey(ourSecret: client.secret, theirPublicKey: bridge.publicKey)
        let theirs = try NIP44.conversationKey(ourSecret: bridge.secret, theirPublicKey: client.publicKey)
        #expect(ours == theirs)

        let sealed = try NIP44.encrypt(Data("/_matrix/client/versions".utf8), conversationKey: ours)
        #expect(!sealed.contains("_matrix"))
        #expect(try NIP44.decrypt(sealed, conversationKey: theirs) == Data("/_matrix/client/versions".utf8))
    }

    @Test func athirdPartyKeyDoesNotOpenIt() throws {
        let client = try NostrKeypair.generate()
        let bridge = try NostrKeypair.generate()
        let eavesdropper = try NostrKeypair.generate()

        let conversation = try NIP44.conversationKey(ourSecret: client.secret, theirPublicKey: bridge.publicKey)
        let sealed = try NIP44.encrypt(Data("hello".utf8), conversationKey: conversation)

        let wrong = try NIP44.conversationKey(ourSecret: eavesdropper.secret, theirPublicKey: client.publicKey)
        #expect(throws: NIP44.Failure.wrongKeyOrTampered) {
            try NIP44.decrypt(sealed, conversationKey: wrong)
        }
    }

    private func sha256Hex(_ data: Data) -> String {
        Hex.string(Data(CryptoKit.SHA256.hash(data: data)))
    }
}
