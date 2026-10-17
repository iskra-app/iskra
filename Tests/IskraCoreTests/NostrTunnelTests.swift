import Foundation
import Synchronization
import Testing
@testable import IskraCore

/// The parts of the tunnel that can be pinned without a relay: how a bridge address is read, how
/// an event is built, and what a stream frame looks like on the wire.
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
    @Test func asecretKeyIsRefusedAsItself() throws {
        let nsec = try #require(Bech32.encode(prefix: "nsec", bytes: Data(repeating: 1, count: 32)))
        #expect(BridgeAddress.publicKey(from: nsec) == .failure(.looksLikeASecretKey))
    }

    @Test func rubbishIsRefused() throws {
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

    @Test func bech32RoundTrips() throws {
        let bytes = Data((0..<32).map { UInt8($0) })
        let npub = try #require(Bech32.encode(prefix: "npub", bytes: bytes))
        #expect(npub.hasPrefix("npub1"))
        #expect(Bech32.decode(npub)?.bytes == bytes)
        #expect(Bech32.decode(npub)?.prefix == "npub")
    }

    // MARK: - Relays

    @Test func relaysAreSplitAndFiltered() throws {
        let parsed = TunnelSettings.parseRelays("""
        wss://nos.lol, wss://relay.primal.net
        https://example.org
        ws://127.0.0.1:7777
        """)
        #expect(parsed.map(\.absoluteString) == ["wss://nos.lol",
                                                 "wss://relay.primal.net",
                                                 "ws://127.0.0.1:7777"])
    }

    @Test func nothingWrittenMeansTheDefaults() throws {
        let defaults = try #require(UserDefaults(suiteName: "relays-\(UUID().uuidString)"))
        #expect(TunnelSettings.relays(defaults).map(\.absoluteString) == TunnelSettings.defaultRelays)
        defaults.set("   ", forKey: TunnelSettings.relaysKey)
        #expect(TunnelSettings.relays(defaults).map(\.absoluteString) == TunnelSettings.defaultRelays)
    }

    // MARK: - Events

    @Test func asignedEventVerifies() throws {
        let keys = try NostrKeypair.generate()
        let event = try NostrEvent.signed(kind: TunnelKind.streamClient,
                                          content: "not really ciphertext",
                                          tags: [["p", Hex.string(keys.publicKey)]],
                                          keys: keys)
        #expect(event.isAuthentic())
        #expect(event.pubkey == Hex.string(keys.publicKey))
        #expect(event.id.count == 64)
        #expect(event.sig.count == 128)
    }

    /// One hostile relay sends a forgery carrying the real answer's id before the real answer
    /// arrives. The forgery must not count as having seen that id, or every honest relay's copy is
    /// dropped as a duplicate.
    @Test func aForgeryDoesNotShadowTheRealEvent() async throws {
        let keys = try NostrKeypair.generate()
        let real = try NostrEvent.signed(kind: TunnelKind.streamBridge, content: "the answer",
                                         tags: [], keys: keys)
        var forged = real
        forged.content = "not the answer"

        let delivered = Mutex<[String]>([])
        let pool = NostrRelayPool(relays: [],
                                  filter: NostrFilter(kinds: [], authors: [], recipients: [], since: 0),
                                  onEvent: { event in delivered.withLock { $0.append(event.content) } })
        let relay = try #require(URL(string: "wss://relay.example"))
        func frame(_ event: NostrEvent) throws -> String {
            let data = try JSONSerialization.data(withJSONObject: ["EVENT", "sub", event.json])
            return try #require(String(bytes: data, encoding: .utf8))
        }

        await pool.handle(try frame(forged), from: relay)
        await pool.handle(try frame(real), from: relay)
        await pool.handle(try frame(real), from: relay)

        #expect(delivered.withLock { $0 } == ["the answer"])
    }

    /// An event whose content has been changed no longer hashes to its id. This is what stops a
    /// relay from handing us somebody else's answer with the bridge's name on it.
    @Test func atamperedEventDoesNotVerify() throws {
        let keys = try NostrKeypair.generate()
        var event = try NostrEvent.signed(kind: TunnelKind.streamClient, content: "one",
                                          tags: [], keys: keys)
        event.content = "two"
        #expect(!event.isAuthentic())
    }

    /// The id is a hash of exactly these bytes, so the serialization is part of the protocol and
    /// not an implementation detail. Pinned: no whitespace, the fields in NIP-01's order, and only
    /// the escapes NIP-01 names.
    @Test func theSerializationIsExactly() throws {
        let serialized = NostrEvent.serialize(pubkey: String(repeating: "a", count: 64),
                                              createdAt: 1_700_000_000,
                                              kind: 20_010,
                                              tags: [["p", "beef"]],
                                              content: "a \"quote\",\na tab\there")
        #expect(serialized == #"[0,"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",1700000000,20010,[["p","beef"]],"a \"quote\",\na tab\there"]"#)
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

    /// The notification extension decides the route from these settings too, and its own
    /// `.standard` is empty. Kept there, the extension went straight to the homeserver on every
    /// push with the bridge switched on.
    @Test func theBridgeSettingsAreReadFromTheAppGroup() throws {
        let shared = try #require(ChatDirectory.sharedDefaults)
        let saved = shared.object(forKey: TunnelSettings.enabledKey)
        defer {
            if let saved { shared.set(saved, forKey: TunnelSettings.enabledKey) } else {
                shared.removeObject(forKey: TunnelSettings.enabledKey)
            }
        }

        shared.set(true, forKey: TunnelSettings.enabledKey)
        #expect(TunnelSettings.isEnabled())
        shared.set(false, forKey: TunnelSettings.enabledKey)
        #expect(!TunnelSettings.isEnabled())
    }

}

// MARK: - Stream frames

/// The same strings `stream.rs`'s `frames_are_exactly_this_json` pins, so a field renamed on either
/// side shows up as a test, not as a tunnel that silently never opens.
extension NostrTunnelTests {
    private static let sid = "6f1c2a7e-0000-4000-8000-000000000001"

    @Test func streamFramesAreExactlyThisJSON() throws {
        let hi = Data("hi".utf8)
        let cases: [(StreamFrame, String)] = [
            (.open(Self.sid, host: "matrix-client.matrix.org", port: 443, first: hi),
             #"{"v":2,"sid":"6f1c2a7e-0000-4000-8000-000000000001","op":"open","host":"matrix-client.matrix.org","port":443,"seq":0,"data":"aGk="}"#),
            (.opened(Self.sid),
             #"{"v":2,"sid":"6f1c2a7e-0000-4000-8000-000000000001","op":"opened"}"#),
            (.data(Self.sid, seq: 7, bytes: hi),
             #"{"v":2,"sid":"6f1c2a7e-0000-4000-8000-000000000001","op":"data","seq":7,"data":"aGk="}"#),
            (.ack(Self.sid, 12),
             #"{"v":2,"sid":"6f1c2a7e-0000-4000-8000-000000000001","op":"ack","ack":12}"#),
            (.fin(Self.sid, seq: 13),
             #"{"v":2,"sid":"6f1c2a7e-0000-4000-8000-000000000001","op":"fin","seq":13}"#),
            (.rst(Self.sid, reason: StreamReason.notMatrix),
             #"{"v":2,"sid":"6f1c2a7e-0000-4000-8000-000000000001","op":"rst","reason":"not matrix"}"#),
        ]
        for (frame, json) in cases {
            _ = try frame.validated()
            #expect(String(decoding: frame.wire, as: UTF8.self) == json)
            #expect(try JSONDecoder().decode(StreamFrame.self, from: Data(json.utf8)) == frame)
        }
    }

    /// Base64 carries `/`, and an escaped `\/` is a different string to anybody comparing text.
    @Test func streamFramesDoNotEscapeSlashes() throws {
        let frame = StreamFrame.data(Self.sid, seq: 1, bytes: Data([0xff, 0xff, 0xff]))
        #expect(String(decoding: frame.wire, as: UTF8.self).contains(#""data":"////""#))
    }

    @Test func aStreamFrameWithAFieldItsOpDoesNotCarryIsRefused() {
        var ack = StreamFrame.ack(Self.sid, 3)
        ack.seq = 3
        #expect(throws: TunnelProtocolError.self) { try ack.validated() }

        var data = StreamFrame.data(Self.sid, seq: 1, bytes: Data("x".utf8))
        data.host = "matrix.org"
        #expect(throws: TunnelProtocolError.self) { try data.validated() }
    }

    @Test func aStreamFrameMissingAFieldItsOpNeedsIsRefused() {
        var open = StreamFrame.open(Self.sid, host: "matrix.org", port: 443, first: Data("x".utf8))
        open.port = nil
        #expect(throws: TunnelProtocolError.self) { try open.validated() }

        var data = StreamFrame.data(Self.sid, seq: 1, bytes: Data("x".utf8))
        data.seq = nil
        #expect(throws: TunnelProtocolError.self) { try data.validated() }
    }

    @Test func openIsSegmentZeroAndNothingElse() {
        var open = StreamFrame.open(Self.sid, host: "matrix.org", port: 443, first: Data("x".utf8))
        open.seq = 1
        #expect(throws: TunnelProtocolError.self) { try open.validated() }
    }

    @Test func aV1OrFutureStreamFrameIsRefused() {
        for version: UInt8 in [1, 3] {
            var frame = StreamFrame.opened(Self.sid)
            frame.v = version
            #expect(throws: TunnelProtocolError.unsupportedVersion(version)) { try frame.validated() }
        }
    }

    @Test func anOversizedSegmentIsRefusedBeforeItIsDecoded() throws {
        let tooBig = StreamFrame.data(Self.sid, seq: 1, bytes: Data(count: StreamFrame.maxSegment + 3))
        #expect(throws: TunnelProtocolError.self) { try tooBig.validated() }
        _ = try StreamFrame.data(Self.sid, seq: 1, bytes: Data(count: StreamFrame.maxSegment)).validated()
    }

    /// The arithmetic `MAX_BODY_CHUNK` rests on, for v2: a full segment, framed and encrypted, is
    /// still an event a public relay takes.
    @Test func aFullSegmentFitsOneNIP44Payload() throws {
        let frame = StreamFrame.data(Self.sid, seq: .max,
                                     bytes: Data(repeating: 0xff, count: StreamFrame.defaultSegment))
        #expect(frame.wire.count < 65_535)
        let keys = try NostrKeypair.generate()
        let bridge = try NostrKeypair.generate()
        let event = try NostrStreamTunnel.seal(frame,
                                               conversationKey: try NIP44.conversationKey(ourSecret: keys.secret,
                                                                                          theirPublicKey: bridge.publicKey),
                                               bridgeKeyHex: Hex.string(bridge.publicKey), keys: keys)
        #expect(event.kind == TunnelKind.streamClient)
        #expect(event.isAuthentic())
    }
}
