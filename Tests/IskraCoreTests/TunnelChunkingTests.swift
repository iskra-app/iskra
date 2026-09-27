import Foundation
import Testing
@testable import IskraCore

/// The chunker and the reassembler, held to the same rules as their Rust twins.
///
/// These are deliberately the same cases as `iskra-tunnel-proto`'s unit tests, case for case: the
/// two implementations are one protocol, and the only way to keep them one is to ask both the same
/// questions. A body that comes back reassembled here and not there is the failure that would
/// otherwise show up as "photos sometimes do not send".
struct TunnelChunkingTests {
    private func request(body: Data, maxBodyChunk: Int) -> [TunnelEnvelope] {
        TunnelChunker.envelopes(id: "abc",
                                method: "POST",
                                path: "/_matrix/media/v3/upload",
                                headers: ["content-type": "image/jpeg"],
                                upstream: "https://matrix.org",
                                body: body,
                                maxBodyChunk: maxBodyChunk)
    }

    private func counting(_ length: Int) -> Data {
        // Not a repeated byte: a body of one repeated character reassembles identically however
        // the chunks are ordered, which is exactly the mistake worth catching.
        Data((0..<length).map { UInt8($0 % 251) })
    }

    // MARK: - Cutting

    @Test func anEmptyBodyIsOneChunkAndNotNone() throws {
        let envelopes = request(body: Data(), maxBodyChunk: 64)
        #expect(envelopes.count == 1)
        #expect(envelopes[0].total == 1)
        #expect(envelopes[0].bodyChunk == "")
        #expect(try envelopes[0].validated().seq == 0)
    }

    @Test func oneByteMoreThanFitsIsTwoChunks() {
        #expect(request(body: counting(64), maxBodyChunk: 64).count == 1)
        #expect(request(body: counting(65), maxBodyChunk: 64).count == 2)
        #expect(TunnelChunker.chunkCount(of: 0, maxBodyChunk: 64) == 1)
        #expect(TunnelChunker.chunkCount(of: 1000, maxBodyChunk: 64) == 16)
    }

    /// Not a saving — `TunnelEnvelope.validated()` refuses head fields anywhere but chunk 0, on
    /// both sides of the tunnel.
    @Test func onlyTheFirstChunkCarriesTheHead() throws {
        let envelopes = request(body: counting(200), maxBodyChunk: 64)
        #expect(envelopes.count == 4)
        #expect(envelopes[0].method == "POST")
        #expect(envelopes[0].upstream == "https://matrix.org")
        #expect(envelopes[0].headers?["content-type"] == "image/jpeg")
        for envelope in envelopes.dropFirst() {
            #expect(envelope.method == nil)
            #expect(envelope.path == nil)
            #expect(envelope.headers == nil)
            #expect(envelope.upstream == nil)
        }
        for envelope in envelopes {
            _ = try envelope.validated()
        }
    }

    /// The budget is what keeps an event inside a relay's size limit, so it is checked at the size
    /// actually sent rather than in principle.
    @Test func everyChunkAtTheDefaultBudgetFitsOneNIP44Payload() throws {
        let envelopes = request(body: counting(TunnelChunker.defaultMaxBodyChunk * 3 + 1),
                                maxBodyChunk: TunnelChunker.defaultMaxBodyChunk)
        #expect(envelopes.count == 4)
        let encoder = JSONEncoder()
        for envelope in envelopes {
            #expect(try encoder.encode(envelope).count < 65_535)
        }
    }

    // MARK: - Putting back together

    private func reassemble(_ envelopes: [TunnelEnvelope],
                            limits: TunnelReassembler.Limits = .init()) -> TunnelReassembler.Accepted {
        var reassembler = TunnelReassembler(limits: limits)
        var last: TunnelReassembler.Accepted = .waiting
        for envelope in envelopes {
            last = reassembler.accept(envelope, key: envelope.id)
        }
        return last
    }

    private func body(of accepted: TunnelReassembler.Accepted) -> Data? {
        if case .complete(_, let body) = accepted { return body }
        return nil
    }

    @Test func chunksInOrderComeBackAsTheBodyThatWentIn() {
        let original = counting(1000)
        let accepted = reassemble(request(body: original, maxBodyChunk: 64))
        #expect(body(of: accepted) == original)
        if case .complete(let head, _) = accepted {
            #expect(head.method == "POST")
        }
    }

    /// Relays do not agree on order, so the head is not guaranteed to be first — and a body chunk
    /// that arrives before it must not be dropped for having no status on it.
    @Test func chunksOutOfOrderAreFineIncludingTheHeadArrivingLast() {
        let original = counting(300)
        let accepted = reassemble(request(body: original, maxBodyChunk: 64).reversed())
        #expect(body(of: accepted) == original)
    }

    @Test func duplicatesAreNotCountedTwice() {
        var reassembler = TunnelReassembler()
        let envelopes = request(body: counting(200), maxBodyChunk: 64)

        for _ in 0..<3 {
            if case .complete = reassembler.accept(envelopes[0], key: "abc") {
                Issue.record("three copies of one chunk finished the message")
            }
        }
        var last: TunnelReassembler.Accepted = .waiting
        for envelope in envelopes.dropFirst() {
            last = reassembler.accept(envelope, key: "abc")
        }
        #expect(body(of: last)?.count == 200)
        #expect(reassembler.inFlight == 0)
    }

    @Test func aMessageWithMoreChunksThanAllowedIsRefusedAtTheFirstOne() {
        var reassembler = TunnelReassembler(limits: .init(maxChunks: 4))
        let envelopes = request(body: counting(1000), maxBodyChunk: 64)
        guard case .refused(let reason) = reassembler.accept(envelopes[0], key: "abc") else {
            Issue.record("a sixteen-chunk message was accepted at a ceiling of four")
            return
        }
        #expect(reason == "too many chunks")
        #expect(reassembler.inFlight == 0)
    }

    @Test func aMessageThatGrowsPastTheByteCeilingIsDropped() {
        var reassembler = TunnelReassembler(limits: .init(maxBytes: 100))
        let envelopes = request(body: counting(300), maxBodyChunk: 64)

        _ = reassembler.accept(envelopes[0], key: "abc")
        guard case .refused(let reason) = reassembler.accept(envelopes[1], key: "abc") else {
            Issue.record("the ceiling was not enforced")
            return
        }
        #expect(reason == "message is too large")
        #expect(reassembler.inFlight == 0)
    }

    /// Messages begun and never finished are the cheapest attack there is on anything that holds
    /// chunks in memory — and on a phone the memory is somebody's.
    @Test func aFloodOfUnfinishedMessagesIsRefusedRatherThanHeld() {
        var reassembler = TunnelReassembler(limits: .init(maxInFlight: 2))
        let envelopes = request(body: counting(300), maxBodyChunk: 64)

        #expect(reassembler.inFlight == 0)
        _ = reassembler.accept(envelopes[0], key: "one")
        _ = reassembler.accept(envelopes[0], key: "two")
        guard case .refused(let reason) = reassembler.accept(envelopes[0], key: "three") else {
            Issue.record("a third message was taken at a ceiling of two")
            return
        }
        #expect(reason == "too many messages in flight")
    }

    /// And the rule that makes that cap survivable: a bridge that goes away mid-answer does not
    /// hold a slot for the life of the app.
    @Test func halfArrivedMessagesAreForgottenAfterTheirTime() {
        var reassembler = TunnelReassembler()
        let envelopes = request(body: counting(300), maxBodyChunk: 64)
        let start = ContinuousClock.now

        _ = reassembler.accept(envelopes[0], key: "old", now: start)
        #expect(reassembler.inFlight == 1)

        _ = reassembler.accept(envelopes[0], key: "new", now: start.advanced(by: .seconds(61)))
        #expect(reassembler.inFlight == 1)
    }

    @Test func aTotalThatChangesMidMessageIsALieAndTheMessageGoes() {
        var reassembler = TunnelReassembler()
        let envelopes = request(body: counting(300), maxBodyChunk: 64)
        var liar = envelopes[1]
        liar.total += 1

        _ = reassembler.accept(envelopes[0], key: "abc")
        guard case .refused(let reason) = reassembler.accept(liar, key: "abc") else {
            Issue.record("two different lengths for one message were accepted")
            return
        }
        #expect(reason == "total changed mid-message")
        #expect(reassembler.inFlight == 0)
    }

    /// A refusal is final. Without this the chunk after a refused one finds no partial, opens a
    /// fresh one and starts filling it — refused, reopened and refused again, once per chunk.
    @Test func theRestOfARefusedMessageDoesNotReopenIt() {
        var reassembler = TunnelReassembler(limits: .init(maxBytes: 100))
        let envelopes = request(body: counting(300), maxBodyChunk: 64)

        _ = reassembler.accept(envelopes[0], key: "abc")
        guard case .refused("message is too large") = reassembler.accept(envelopes[1], key: "abc") else {
            Issue.record("the ceiling was not enforced")
            return
        }
        for envelope in envelopes.dropFirst(2) {
            guard case .refused(let reason) = reassembler.accept(envelope, key: "abc") else {
                Issue.record("a later chunk reopened a refused message")
                return
            }
            #expect(reason == "refused earlier")
        }
        #expect(reassembler.inFlight == 0)
    }

    @Test func aMessageIsKnownFromItsFirstChunkUntilItIsDone() {
        var reassembler = TunnelReassembler()
        let envelopes = request(body: counting(200), maxBodyChunk: 64)

        #expect(!reassembler.knows("abc"))
        _ = reassembler.accept(envelopes[0], key: "abc")
        #expect(reassembler.knows("abc"))
        for envelope in envelopes.dropFirst() {
            _ = reassembler.accept(envelope, key: "abc")
        }
        #expect(!reassembler.knows("abc"))
    }

    /// Given up on — the deadline passed, or the answer is in — a chunk arriving late neither
    /// reopens the message nor sits in memory for a minute; and after a minute it is all forgotten.
    @Test func aMessageGivenUpOnStaysGoneUntilItsTimeIsUp() {
        var reassembler = TunnelReassembler()
        let envelopes = request(body: counting(200), maxBodyChunk: 64)
        let start = ContinuousClock.now

        _ = reassembler.accept(envelopes[0], key: "abc", now: start)
        reassembler.forget("abc", now: start)
        #expect(reassembler.inFlight == 0)
        guard case .refused("refused earlier") = reassembler.accept(envelopes[1], key: "abc", now: start) else {
            Issue.record("a late chunk reopened a message already given up on")
            return
        }

        guard case .waiting = reassembler.accept(envelopes[1], key: "abc",
                                                 now: start.advanced(by: .seconds(61))) else {
            Issue.record("a refusal outlived its time")
            return
        }
    }

    @Test func anAnswerReassemblesWithItsStatus() {
        let envelopes = TunnelChunker.envelopes(id: "r",
                                                status: 206,
                                                headers: ["content-type": "image/jpeg"],
                                                body: counting(200),
                                                maxBodyChunk: 64)
        guard case .complete(let head, let body) = reassemble(envelopes) else {
            Issue.record("the answer did not come back")
            return
        }
        #expect(head.status == 206)
        #expect(head.headers?["content-type"] == "image/jpeg")
        #expect(body == counting(200))
    }

    /// A megabyte, which is what a photo coming back looks like: 43 chunks, and every byte in the
    /// place it started.
    @Test func amegabyteSurvivesAtTheRealBudget() {
        let original = counting(1024 * 1024)
        let envelopes = TunnelChunker.envelopes(id: "r", status: 200, headers: [:], body: original)
        #expect(envelopes.count == 43)
        #expect(body(of: reassemble(envelopes)) == original)
    }
}
