import Foundation
import Testing
@testable import IskraCore

/// The bridge's words for ending a stream, and what the app makes of them.
@Suite("Bridge refusals")
struct BridgeRefusalTests {
    /// Every word the bridge can send, read out of the Rust source itself — so a word added there
    /// without a case here fails this rather than reaching the screen as "the stream broke" when
    /// it means something a person could act on.
    @Test("every reason the bridge sends is known here")
    func everyRustReasonIsKnown() throws {
        let source = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Bridge/crates/iskra-tunnel-proto/src/stream.rs")
        let rust = try String(contentsOf: source, encoding: .utf8)
        let module = try #require(rust.range(of: "pub mod reason {"))
        let body = rust[module.upperBound...].prefix { $0 != "}" }
        let words = body.split(separator: "\n").compactMap { line -> String? in
            guard line.contains("pub const"), let open = line.firstIndex(of: "\""),
                  let close = line[line.index(after: open)...].firstIndex(of: "\"") else { return nil }
            return String(line[line.index(after: open)..<close])
        }
        #expect(words.count >= 17, "\(words)")

        // The words that are the stream breaking, and nothing a person could fix.
        let breaking: Set = ["gap", "window", "protocol", "upstream", "idle", "expired", "closed"]
        for word in words {
            // `pow` is only ever sent with the difficulty after it.
            let sent = word == StreamReason.pow ? "\(word) 16" : word
            let refusal = BridgeRefusal(reason: sent)
            if breaking.contains(word) {
                #expect(refusal == .broke(word), "\(word)")
            } else {
                if case .broke = refusal { Issue.record("\"\(word)\" has no case of its own") }
            }
        }
    }

    @Test("only the bridge saying no to the server is a refusal")
    func whatCountsAsARefusal() {
        for word in [StreamReason.notAllowed, StreamReason.notMatrix, StreamReason.badPort,
                     StreamReason.notPublic, StreamReason.noSuchHost] {
            #expect(BridgeRefusal(reason: word).isRefusal, "\(word)")
        }
        for word in [StreamReason.busy, StreamReason.unreachable, StreamReason.sniMismatch, StreamReason.gap] {
            #expect(!BridgeRefusal(reason: word).isRefusal, "\(word)")
        }
    }

    @Test("a pow refusal carries the difficulty, and reads as a busy bridge")
    func powRefusal() {
        #expect(StreamReason.powRequired("pow 20") == 20)
        #expect(StreamReason.powRequired("pow") == nil)
        #expect(StreamReason.powRequired("powder 3") == nil)
        #expect(StreamReason.powRequired("not matrix") == nil)
        #expect(BridgeRefusal(reason: "pow 20") == .busy)
    }

    /// A broken or hostile bridge cannot set the phone mining until the battery is gone.
    @Test("a difficulty past the ceiling is ignored, and mining it is refused")
    func powCeiling() throws {
        #expect(StreamReason.powRequired("pow 24") == 24)
        #expect(StreamReason.powRequired("pow 25") == nil)
        #expect(StreamReason.powRequired("pow 255") == nil)
        let keys = try NostrKeypair.generate()
        #expect(throws: NostrEvent.MiningError.tooHard(40)) {
            try NostrEvent.mined(kind: TunnelKind.streamClient, content: "x", tags: [], bits: 40, keys: keys)
        }
    }

    /// NIP-13 as the bridge checks it: the id starts with that many zero bits, the `nonce` tag
    /// commits to the same target, and the event is still a correctly signed event.
    @Test("an open is mined to its difficulty and still verifies")
    func miningProducesTheWork() throws {
        let keys = try NostrKeypair.generate()
        let event = try NostrEvent.mined(kind: TunnelKind.streamClient, content: "hello",
                                         tags: [["p", String(repeating: "ab", count: 32)]],
                                         bits: 12, keys: keys)
        let id = try #require(Hex.data(event.id))
        #expect(NostrEvent.leadingZeroBits(id) >= 12)
        let nonce = try #require(event.tags.last)
        #expect(nonce.first == "nonce" && nonce.last == "12", "\(nonce)")
        #expect(event.isAuthentic())

        let plain = try NostrEvent.mined(kind: TunnelKind.streamClient, content: "hello", tags: [],
                                         bits: 0, keys: keys)
        #expect(plain.tags.isEmpty, "no work asked, no nonce")
    }

    /// The pieces mining hashes are the serialization the id is checked against, with or without
    /// other tags before the nonce, and with content that needs escaping.
    @Test("the mined pieces are the serialization, nonce and all")
    func minedPartsAreTheSerialization() {
        for tags in [[], [["p", "ab"]], [["p", "ab"], ["e", "x\"y"]]] {
            let (prefix, suffix) = NostrEvent.minedParts(pubkey: "pk", createdAt: 7, kind: 20010, tags: tags,
                                                         bits: 16, content: "a\"b\nc")
            let whole = NostrEvent.serialize(pubkey: "pk", createdAt: 7, kind: 20010,
                                             tags: tags + [["nonce", "4242", "16"]], content: "a\"b\nc")
            #expect(prefix + "4242" + suffix == whole, "\(tags)")
        }
    }

    @Test("zero bits are counted the way NIP-13 counts them")
    func leadingZeroBits() {
        #expect(NostrEvent.leadingZeroBits(Data([0x00, 0x00, 0x0f, 0xff])) == 20)
        #expect(NostrEvent.leadingZeroBits(Data([0x80])) == 0)
        #expect(NostrEvent.leadingZeroBits(Data([0x00, 0x01])) == 15)
    }

    private func frame(_ op: StreamFrame.Op, reason: String? = nil) -> StreamFrame {
        StreamFrame(sid: UUID().uuidString, op: op, reason: reason)
    }

    /// "The bridge cannot see your messages" waits for a stream the bridge actually connected.
    @Test("the status claims nothing until the bridge has connected a stream")
    func statusWaitsForAnOpenedStream() {
        let heard = Heard()
        #expect(TunnelStatus(heard: heard, relays: 3) == .connecting(relays: 3))
        heard.frame(frame(.opened))
        #expect(TunnelStatus(heard: heard, relays: 3) == .bridgedBlind(relays: 3))
    }

    @Test("a bridge refusing now is refusing, even after carrying something earlier")
    func theLastWordDecides() {
        let heard = Heard()
        heard.frame(frame(.opened))
        heard.frame(frame(.rst, reason: StreamReason.notAllowed))
        #expect(TunnelStatus(heard: heard, relays: 2) == .refused(.notAllowed))
        // A stream that merely broke is not a refusal; what was carried still was.
        heard.frame(frame(.rst, reason: StreamReason.gap))
        #expect(TunnelStatus(heard: heard, relays: 2) == .bridgedBlind(relays: 2))
        heard.frame(frame(.opened))
        #expect(TunnelStatus(heard: heard, relays: 2) == .bridgedBlind(relays: 2))
    }

    /// A refusal from an earlier attempt is not this attempt's.
    @Test("a refusal is counted only from the mark")
    func refusalSinceMark() {
        let heard = Heard()
        heard.frame(frame(.rst, reason: StreamReason.notMatrix))
        let mark = heard.mark
        #expect(heard.refusal(since: mark) == nil)
        heard.frame(frame(.rst, reason: StreamReason.notAllowed))
        #expect(heard.refusal(since: mark) == .notAllowed)
    }
}
