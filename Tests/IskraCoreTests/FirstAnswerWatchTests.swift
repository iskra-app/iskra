import Testing
import MatrixRustSDK
@testable import IskraCore

/// Holds the two rules that decide whether the chat list admits it is waiting for the server —
/// the gap that left a list looking up to date for minutes behind a VPN that had lost its way.
@Suite struct FirstAnswerWatchTests {
    /// Only the states the SDK stores after a request came back count as an answer. `terminated`
    /// is what a trip to the pocket leaves behind, and it must not.
    @Test func onlyStatesStoredAfterAnAnswerCount() {
        #expect(FirstAnswerWatch.answered(.settingUp))
        #expect(FirstAnswerWatch.answered(.recovering))
        #expect(FirstAnswerWatch.answered(.running))
        #expect(!FirstAnswerWatch.answered(.terminated))
        #expect(!FirstAnswerWatch.answered(.error))
        #expect(!FirstAnswerWatch.answered(.initial))
    }

    @Test func waitsOnlyWhileSyncIsMeantToBeUp() {
        #expect(FirstAnswerWatch.isWaiting(stopped: false, paused: false, offline: false, answered: false))
        #expect(!FirstAnswerWatch.isWaiting(stopped: false, paused: false, offline: false, answered: true))
        #expect(!FirstAnswerWatch.isWaiting(stopped: false, paused: true, offline: false, answered: false))
        #expect(!FirstAnswerWatch.isWaiting(stopped: false, paused: false, offline: true, answered: false))
        #expect(!FirstAnswerWatch.isWaiting(stopped: true, paused: false, offline: false, answered: false))
    }

    @Test func updatingComesBeforeStalled() {
        #expect(FirstAnswerWatch.updatingAfter < FirstAnswerWatch.stalledAfter)
    }
}
