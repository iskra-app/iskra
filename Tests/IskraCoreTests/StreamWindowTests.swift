import Foundation
import Testing
@testable import IskraCore

/// Protocol v2's reassembly and window, asked the questions `stream.rs` asks of its own — case for
/// case, under the same names. Two programs that put a stream back together differently fail only
/// under load, only sometimes, and only in production; the cure is that both answer the same
/// questions the same way.
struct StreamWindowTests {
    private func segment(_ n: UInt8) -> Data { Data(repeating: n, count: 10) }
    private let start = ContinuousClock.now

    // MARK: - The receiver

    @Test func inOrderSegmentsGoStraightOut() throws {
        var inbound = StreamInbound()
        #expect(try inbound.accept(0, segment(0), now: start) == [segment(0)])
        #expect(try inbound.accept(1, segment(1), now: start) == [segment(1)])
        #expect(!inbound.gapExpired(now: start + .seconds(10)))
    }

    /// Segment 2 before 1: held, then both go out, in order, when 1 arrives.
    @Test func aReorderedSegmentWaitsForTheHoleAndThenBothGo() throws {
        var inbound = StreamInbound()
        _ = try inbound.accept(0, segment(0), now: start)
        #expect(try inbound.accept(2, segment(2), now: start).isEmpty)
        #expect(try inbound.accept(1, segment(1), now: start) == [segment(1), segment(2)])
        #expect(inbound.gapDeadline == nil)
    }

    @Test func aDuplicateIsNothingWhetherDeliveredOrHeld() throws {
        var inbound = StreamInbound()
        _ = try inbound.accept(0, segment(0), now: start)
        _ = try inbound.accept(2, segment(2), now: start)
        #expect(try inbound.accept(0, segment(0), now: start).isEmpty)
        #expect(try inbound.accept(2, segment(2), now: start).isEmpty)
        #expect(try inbound.accept(1, segment(1), now: start) == [segment(1), segment(2)])
    }

    /// A segment no relay delivered never comes. The hole is a reset, not a wait.
    @Test func aHoleIsGivenUpOnAfterTheGapTimeout() throws {
        var inbound = StreamInbound()
        _ = try inbound.accept(0, segment(0), now: start)
        _ = try inbound.accept(2, segment(2), now: start)
        #expect(!inbound.gapExpired(now: start + StreamLimits.gapTimeout - .milliseconds(1)))
        #expect(inbound.gapExpired(now: start + StreamLimits.gapTimeout))
    }

    /// A stream with two holes that fills one keeps going: progress restarts the clock.
    @Test func progressRestartsTheGapClock() throws {
        var inbound = StreamInbound()
        _ = try inbound.accept(1, segment(1), now: start)
        _ = try inbound.accept(3, segment(3), now: start)
        let later = start + .seconds(4)
        _ = try inbound.accept(0, segment(0), now: later)
        #expect(!inbound.gapExpired(now: start + StreamLimits.gapTimeout))
        #expect(inbound.gapExpired(now: later + StreamLimits.gapTimeout))
    }

    /// `fin` can overtake the last `data` — different relays, different speeds.
    @Test func finBeforeTheLastDataWaitsForIt() throws {
        var inbound = StreamInbound()
        _ = try inbound.accept(0, segment(0), now: start)
        #expect(try !inbound.finish(2, now: start))
        #expect(inbound.gapDeadline != nil, "a fin ahead of the data is a hole too")
        #expect(try inbound.accept(1, segment(1), now: start) == [segment(1)])
        #expect(inbound.isComplete)
        #expect(inbound.gapDeadline == nil)
    }

    @Test func aDuplicateFinIsFineAndADifferentOneIsNot() throws {
        var inbound = StreamInbound()
        _ = try inbound.accept(0, segment(0), now: start)
        #expect(try inbound.finish(1, now: start))
        #expect(try inbound.finish(1, now: start))
        #expect(throws: StreamViolation.finMoved) { try inbound.finish(2, now: start) }
    }

    @Test func dataAtOrAfterFinIsAViolation() throws {
        var inbound = StreamInbound()
        _ = try inbound.accept(0, segment(0), now: start)
        _ = try inbound.finish(1, now: start)
        #expect(throws: StreamViolation.dataAfterFin) { try inbound.accept(1, segment(1), now: start) }
    }

    @Test func aFinBelowWhatExistsIsAViolation() throws {
        var inbound = StreamInbound()
        _ = try inbound.accept(0, segment(0), now: start)
        _ = try inbound.accept(1, segment(1), now: start)
        #expect(throws: StreamViolation.finMoved) { try inbound.finish(1, now: start) }

        var held = StreamInbound()
        _ = try held.accept(3, segment(3), now: start)
        #expect(throws: StreamViolation.finMoved) { try held.finish(3, now: start) }
    }

    @Test func aSegmentPastTheWindowIsAViolation() throws {
        var inbound = StreamInbound()
        #expect(throws: StreamViolation.beyondWindow) {
            try inbound.accept(StreamLimits.windowSegments, segment(0), now: start)
        }
        _ = try inbound.accept(StreamLimits.windowSegments - 1, segment(0), now: start)
    }

    /// A sender that ignores acknowledgements is refused even when it sends in order: what has not
    /// reached the socket counts against the window as much as what is waiting on a hole.
    @Test func inOrderSegmentsPastAnUnwrittenWindowAreAViolation() throws {
        var inbound = StreamInbound()
        for seq in 0..<StreamLimits.windowSegments {
            #expect(try inbound.accept(seq, segment(0), now: start).count == 1)
        }
        #expect(throws: StreamViolation.beyondWindow) {
            try inbound.accept(StreamLimits.windowSegments, segment(0), now: start)
        }
        _ = inbound.written(segments: 1, bytes: 10)
        #expect(try inbound.accept(StreamLimits.windowSegments, segment(0), now: start).count == 1)
    }

    @Test func unwrittenBytesPastTheWindowAreAViolation() throws {
        var inbound = StreamInbound()
        let big = Data(count: StreamFrame.maxSegment)
        var seq: UInt32 = 0
        var refused: StreamViolation?
        while refused == nil {
            do {
                _ = try inbound.accept(seq, big, now: start)
                seq += 1
            } catch {
                refused = error
            }
        }
        #expect(refused == .beyondWindow)
        _ = inbound.written(segments: seq, bytes: Int(seq) * StreamFrame.maxSegment)
        _ = try inbound.accept(seq, big, now: start)
    }

    @Test func heldBytesPastTheWindowAreAViolation() throws {
        var inbound = StreamInbound()
        let big = Data(count: StreamFrame.maxSegment)
        var seq: UInt32 = 1
        var refused: StreamViolation?
        while refused == nil {
            do {
                _ = try inbound.accept(seq, big, now: start)
                seq += 1
            } catch {
                refused = error
            }
        }
        #expect(refused == .beyondWindow)
        #expect(Int(seq) * StreamFrame.maxSegment > StreamLimits.windowBytes)
    }

    @Test func acksComeEveryEightSegments() {
        var inbound = StreamInbound()
        for n in 1..<StreamLimits.ackEverySegments {
            #expect(inbound.written(segments: 1, bytes: 10) == nil, "segment \(n)")
        }
        #expect(inbound.written(segments: 1, bytes: 10) == StreamLimits.ackEverySegments)
        #expect(inbound.written(segments: 1, bytes: 10) == nil)
    }

    @Test func orEveryQuarterMebibyte() {
        var inbound = StreamInbound()
        #expect(inbound.written(segments: 1, bytes: StreamLimits.ackEveryBytes - 1) == nil)
        #expect(inbound.written(segments: 1, bytes: 1) == 2)
    }

    // MARK: - The sender

    @Test func theWindowClosesAtItsByteLimitAndAnAckOpensIt() throws {
        var outbound = StreamOutbound.afterOpen(100)
        let chunk = 24 * 1024
        while outbound.hasRoom(chunk) { outbound.push(chunk) }
        #expect(outbound.unackedBytes + chunk > StreamLimits.windowBytes)
        try outbound.ack(outbound.nextSeq)
        #expect(outbound.unackedBytes == 0)
        #expect(outbound.hasRoom(chunk))
    }

    @Test func theWindowClosesAtItsSegmentLimitHoweverSmallTheyAre() throws {
        var outbound = StreamOutbound()
        while outbound.isOpen { outbound.push(1) }
        #expect(outbound.nextSeq == StreamLimits.windowSegments)
        try outbound.ack(1)
        #expect(outbound.isOpen)
    }

    @Test func anEmptyWindowAdmitsOneSegmentOfAnySize() {
        #expect(StreamOutbound().hasRoom(StreamLimits.windowBytes * 4))
    }

    /// A late ack from a slow relay is old news, not a violation.
    @Test func aStaleAckChangesNothing() throws {
        var outbound = StreamOutbound()
        for _ in 0..<4 { outbound.push(10) }
        try outbound.ack(3)
        try outbound.ack(1)
        #expect(outbound.unackedBytes == 10)
    }

    @Test func anAckBeyondWhatWasSentIsAViolation() throws {
        var outbound = StreamOutbound()
        outbound.push(10)
        #expect(throws: StreamViolation.ackBeyondSent) { try outbound.ack(2) }
        try outbound.ack(1)
    }

    /// The two halves together: a sender that respects the window can never make a receiver
    /// refuse, whatever order the relays deliver in.
    @Test func aSenderInsideItsWindowNeverTripsTheReceiver() throws {
        var outbound = StreamOutbound()
        var inbound = StreamInbound()
        var delivered: UInt32 = 0
        for round in 0..<20 {
            var queued: [(UInt32, Data)] = []
            while outbound.hasRoom(24 * 1024) {
                let seq = outbound.push(24 * 1024)
                queued.append((seq, Data(repeating: UInt8(round), count: 24 * 1024)))
            }
            // Delivered newest first: the worst order there is.
            for (seq, bytes) in queued.reversed() {
                for ready in try inbound.accept(seq, bytes, now: start) {
                    delivered += 1
                    if let ack = inbound.written(segments: 1, bytes: ready.count) {
                        try outbound.ack(ack)
                    }
                }
            }
        }
        #expect(delivered == outbound.nextSeq)
    }
}
