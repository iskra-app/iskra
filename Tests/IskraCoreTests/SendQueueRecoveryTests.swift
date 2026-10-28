import Foundation
import Testing
import MatrixRustSDK
@testable import IskraCore

/// A message written into a bad connection waits with a clock and goes when it can — the SDK keeps
/// it, and `SendQueueRecovery` decides when to start the stopped queue again. These are the rules
/// for that pause, and for how a send state reads on the bubble.
@Suite("Send queue recovery")
struct SendQueueRecoveryTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("The pause doubles with each failure in a row, up to the ceiling")
    func backoffDoubles() {
        var recovery = SendQueueRecovery()
        let pauses = (0..<8).map { recovery.failed(at: start.addingTimeInterval(Double($0))) }

        #expect(pauses == [.seconds(1), .seconds(2), .seconds(4), .seconds(8),
                           .seconds(16), .seconds(30), .seconds(30), .seconds(30)])
    }

    @Test("A failure after a quiet spell starts the run again")
    func quietSpellResets() {
        var recovery = SendQueueRecovery()
        _ = recovery.failed(at: start)
        _ = recovery.failed(at: start.addingTimeInterval(1))
        #expect(recovery.failed(at: start.addingTimeInterval(2)) == .seconds(4))

        let later = start.addingTimeInterval(2 + SendQueueRecovery.quietPeriod + 1)
        #expect(recovery.failed(at: later) == .seconds(1))
    }

    @Test("A queue failing at the ceiling never looks quiet")
    func ceilingIsShorterThanQuiet() {
        #expect(SendQueueRecovery.ceiling < SendQueueRecovery.quietPeriod)
    }

    @Test("The network coming back forgets the run")
    func resetForgets() {
        var recovery = SendQueueRecovery()
        _ = recovery.failed(at: start)
        _ = recovery.failed(at: start)
        recovery.reset()
        #expect(recovery.failed(at: start) == .seconds(1))
    }

    @Test("Upload progress is a fraction, and nothing until there is a total")
    func uploadProgress() {
        func state(_ current: UInt64, of total: UInt64) -> EventSendState {
            .notSentYet(progress: MediaUploadProgress(index: 0,
                                                      progress: AbstractProgress(current: current, total: total)))
        }

        #expect(TimelineMapper.uploadProgress(of: state(25, of: 100)) == 0.25)
        #expect(TimelineMapper.uploadProgress(of: state(120, of: 100)) == 1)
        #expect(TimelineMapper.uploadProgress(of: state(0, of: 0)) == nil)
        #expect(TimelineMapper.uploadProgress(of: .notSentYet(progress: nil)) == nil)
        #expect(TimelineMapper.uploadProgress(of: .sent(eventId: "$x")) == nil)
        #expect(TimelineMapper.uploadProgress(of: nil) == nil)
    }
}
