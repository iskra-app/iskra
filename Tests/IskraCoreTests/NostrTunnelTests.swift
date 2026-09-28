import Foundation
import Testing
@testable import IskraCore

/// The parts of the tunnel that can be pinned without a relay: how a bridge address is read, how
/// an event is built, and what the envelope looks like on the wire.
struct NostrTunnelTests {
    // MARK: - The address somebody pastes

    @Test func hexAndNpubAreTheSameKey() throws {
        let keys = try NostrKeypair.generate()
        let hex = Hex.string(keys.publicKey)

        #expect(BridgeAddress.publicKey(from: hex) == .success(keys.publicKey))
        #expect(BridgeAddress.publicKey(from: keys.npub) == .success(keys.publicKey))
        // Pasted out of a terminal, with whatever came with it.
        #expect(BridgeAddress.publicKey(from: "  \(hex)\n") == .success(keys.publicKey))
    }

    /// A secret key in this field is a mistake worth naming. Deriving the public key from it and
    /// carrying on would leave somebody's secret in `UserDefaults` with nothing said about it.
    @Test func asecretKeyIsRefusedAsItself() {
        let nsec = Bech32.encode(prefix: "nsec", bytes: Data(repeating: 1, count: 32))!
        #expect(BridgeAddress.publicKey(from: nsec) == .failure(.looksLikeASecretKey))
    }

    @Test func rubbishIsRefused() {
        #expect(BridgeAddress.publicKey(from: "") == .failure(.empty))
        #expect(BridgeAddress.publicKey(from: "   ") == .failure(.empty))
        #expect(BridgeAddress.publicKey(from: "matrix.org") == .failure(.notAKey))
        // One character short of a key, which is what a truncated paste looks like.
        #expect(BridgeAddress.publicKey(from: String(repeating: "a", count: 63)) == .failure(.notAKey))
        // The right length, and not a point on the curve.
        #expect(BridgeAddress.publicKey(from: String(repeating: "f", count: 64)) == .failure(.notAKey))
    }

    /// The checksum is the reason `npub` is worth accepting at all: one wrong character is caught
    /// here instead of becoming a bridge that never answers.
    @Test func atypoInAnNpubIsCaught() throws {
        let keys = try NostrKeypair.generate()
        var broken = Array(keys.npub)
        broken[broken.count - 3] = broken[broken.count - 3] == "q" ? "p" : "q"
        #expect(BridgeAddress.publicKey(from: String(broken)) == .failure(.notAKey))
    }

    @Test func bech32RoundTrips() {
        let bytes = Data((0..<32).map { UInt8($0) })
        let npub = Bech32.encode(prefix: "npub", bytes: bytes)
        #expect(npub?.hasPrefix("npub1") == true)
        #expect(Bech32.decode(npub!)?.bytes == bytes)
        #expect(Bech32.decode(npub!)?.prefix == "npub")
    }

    // MARK: - Relays

    @Test func relaysAreSplitAndFiltered() {
        let parsed = TunnelSettings.parseRelays("""
        wss://nos.lol, wss://relay.primal.net
        https://example.org
        ws://127.0.0.1:7777
        """)
        #expect(parsed.map(\.absoluteString) == ["wss://nos.lol",
                                                 "wss://relay.primal.net",
                                                 "ws://127.0.0.1:7777"])
    }

    @Test func nothingWrittenMeansTheDefaults() {
        let defaults = UserDefaults(suiteName: "relays-\(UUID().uuidString)")!
        #expect(TunnelSettings.relays(defaults).map(\.absoluteString) == TunnelSettings.defaultRelays)
        defaults.set("   ", forKey: TunnelSettings.relaysKey)
        #expect(TunnelSettings.relays(defaults).map(\.absoluteString) == TunnelSettings.defaultRelays)
    }

    // MARK: - Events

    @Test func asignedEventVerifies() throws {
        let keys = try NostrKeypair.generate()
        let event = try NostrEvent.signed(kind: TunnelKind.request,
                                          content: "not really ciphertext",
                                          tags: [["p", Hex.string(keys.publicKey)]],
                                          keys: keys)
        #expect(event.isAuthentic())
        #expect(event.pubkey == Hex.string(keys.publicKey))
        #expect(event.id.count == 64)
        #expect(event.sig.count == 128)
    }

    /// An event whose content has been changed no longer hashes to its id. This is what stops a
    /// relay from handing us somebody else's answer with the bridge's name on it.
    @Test func atamperedEventDoesNotVerify() throws {
        let keys = try NostrKeypair.generate()
        var event = try NostrEvent.signed(kind: TunnelKind.request, content: "one",
                                          tags: [], keys: keys)
        event.content = "two"
        #expect(!event.isAuthentic())
    }

    /// The id is a hash of exactly these bytes, so the serialization is part of the protocol and
    /// not an implementation detail. Pinned: no whitespace, the fields in NIP-01's order, and only
    /// the escapes NIP-01 names.
    @Test func theSerializationIsExactly() {
        let serialized = NostrEvent.serialize(pubkey: String(repeating: "a", count: 64),
                                              createdAt: 1_700_000_000,
                                              kind: 20_001,
                                              tags: [["p", "beef"]],
                                              content: "a \"quote\",\na tab\there")
        #expect(serialized == #"[0,"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",1700000000,20001,[["p","beef"]],"a \"quote\",\na tab\there"]"#)
    }

    // MARK: - The envelope

    /// Field for field, the JSON the bridge's serde expects. A rename here is a tunnel that fails
    /// on the first request and nowhere else, so the names are pinned as text.
    @Test func theEnvelopeIsSpelledTheWayTheBridgeSpellsIt() throws {
        let envelope = TunnelEnvelope(id: "abc",
                                      seq: 0,
                                      total: 1,
                                      method: "GET",
                                      path: "/_matrix/client/versions",
                                      headers: ["accept": "application/json"],
                                      status: nil,
                                      upstream: "https://matrix-client.matrix.org",
                                      bodyChunk: "")

        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let json = String(decoding: try encoder.encode(envelope), as: UTF8.self)
        #expect(json == #"{"body_chunk":"","headers":{"accept":"application\/json"},"id":"abc","method":"GET","path":"\/_matrix\/client\/versions","seq":0,"total":1,"upstream":"https:\/\/matrix-client.matrix.org","v":1}"#)
        // A response has a status and no method. Absent fields are absent, not null: the bridge
        // refuses head fields on a later chunk, and `null` is a field.
        #expect(!json.contains("status"))
    }

    @Test func aresponseEnvelopeSurvivesTheRoundTrip() throws {
        let envelope = TunnelEnvelope(id: "xyz", seq: 0, total: 1, status: 200,
                                      bodyChunk: Data("{}".utf8).base64EncodedString())
        let data = try JSONEncoder().encode(envelope)
        let back = try JSONDecoder().decode(TunnelEnvelope.self, from: data).validated()
        #expect(back.status == 200)
        #expect(try back.body == Data("{}".utf8))
    }

    /// The same refusals the bridge makes. An envelope that contradicts itself arrives from a
    /// relay, which is to say from anybody.
    @Test func selfContradictoryEnvelopesAreRefused() {
        var envelope = TunnelEnvelope(id: "a", seq: 0, total: 1, status: 200, bodyChunk: "")
        envelope.total = 0
        #expect(throws: TunnelProtocolError.malformed("total is zero")) { try envelope.validated() }

        envelope = TunnelEnvelope(id: "a", seq: 3, total: 2, status: 200, bodyChunk: "")
        #expect(throws: TunnelProtocolError.malformed("seq is past total")) { try envelope.validated() }

        envelope = TunnelEnvelope(id: "a", seq: 1, total: 3, status: 200, bodyChunk: "")
        #expect(throws: TunnelProtocolError.malformed("head fields on a non-first chunk")) {
            try envelope.validated()
        }

        envelope = TunnelEnvelope(v: 2, id: "a", seq: 0, total: 1, bodyChunk: "")
        #expect(throws: TunnelProtocolError.unsupportedVersion(2)) { try envelope.validated() }
    }

    // MARK: - The device's own key

    @Test func theKeypairIsKeptRatherThanRegenerated() throws {
        let secrets = InMemorySecrets()
        let identity = TunnelIdentity(secrets: secrets)
        let first = try identity.keypair()
        #expect(try identity.keypair() == first)

        try identity.forget()
        #expect(try identity.keypair() != first)
    }

    // MARK: - Settings

    @Test func theBridgeKeyComesBackOutOfSettings() throws {
        let defaults = UserDefaults(suiteName: "bridge-\(UUID().uuidString)")!
        #expect(TunnelSettings.bridgeKey(defaults) == nil)

        let keys = try NostrKeypair.generate()
        defaults.set(keys.npub, forKey: TunnelSettings.addressKey)
        #expect(TunnelSettings.bridgeKey(defaults) == keys.publicKey)

        // Half a key is no key, and must not be read as one.
        defaults.set(String(keys.npub.dropLast(4)), forKey: TunnelSettings.addressKey)
        #expect(TunnelSettings.bridgeKey(defaults) == nil)
    }

    /// Leaving the Connection screen rebuilds the session only when the connection would really be
    /// different. Tearing one down to build it again identically is a spinner for nothing.
    @Test func onlyAChangeThatMattersAsksForAReconnect() throws {
        let defaults = UserDefaults(suiteName: "snapshot-\(UUID().uuidString)")!
        let keys = try NostrKeypair.generate()
        defaults.set(true, forKey: TunnelSettings.enabledKey)
        defaults.set(Hex.string(keys.publicKey), forKey: TunnelSettings.addressKey)
        let before = TunnelSettings.snapshot(defaults)

        // The same key as npub, with a stray space; relays emptied back to what the defaults are.
        defaults.set(" \(keys.npub) ", forKey: TunnelSettings.addressKey)
        defaults.set("  ", forKey: TunnelSettings.relaysKey)
        #expect(TunnelSettings.snapshot(defaults) == before)

        defaults.set(false, forKey: TunnelSettings.enabledKey)
        #expect(TunnelSettings.snapshot(defaults) != before)
        defaults.set(true, forKey: TunnelSettings.enabledKey)

        defaults.set("wss://relay.example", forKey: TunnelSettings.relaysKey)
        #expect(TunnelSettings.snapshot(defaults) != before)
    }

    @Test func theOriginIsSchemeHostAndPort() {
        #expect(NostrTunnelUpstream.origin(of: URL(string: "https://matrix.org/_matrix/client")!)
                == "https://matrix.org")
        #expect(NostrTunnelUpstream.origin(of: URL(string: "http://192.168.1.2:8008")!)
                == "http://192.168.1.2:8008")
    }
}
