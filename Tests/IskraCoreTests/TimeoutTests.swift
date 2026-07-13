import Foundation
import Synchronization
import Testing
@testable import IskraCore

@Suite("withTimeout")
struct TimeoutTests {
    @Test("a fast answer is passed straight through")
    func fastAnswerWins() async throws {
        let value = try await withTimeout(.seconds(10)) { "matrix.org" }
        #expect(value == "matrix.org")
    }

    @Test("an error from the operation is the caller's error, not a timeout")
    func operationErrorIsNotSwallowed() async {
        struct Boom: Error, Equatable {}

        await #expect(throws: Boom.self) {
            try await withTimeout(.seconds(10)) { throw Boom() }
        }
    }

    @Test("a slow operation times out")
    func slowOperationTimesOut() async {
        await #expect(throws: TimeoutError.self) {
            try await withTimeout(.milliseconds(50)) {
                try await Task.sleep(for: .seconds(30))
            }
        }
    }

    /// The reason this helper exists rather than a task group. A task group waits for
    /// its children, so an operation that ignores cancellation would hold the caller
    /// past the deadline — which is the hang we are bounding, not a hypothetical.
    @Test("the caller is released even when the operation ignores cancellation")
    func uncancellableOperationStillTimesOut() async {
        let started = ContinuousClock.now

        await #expect(throws: TimeoutError.self) {
            try await withTimeout(.milliseconds(50)) {
                // Deaf to cancellation, exactly like an FFI call stuck in Rust.
                await withUnsafeContinuation { (continuation: UnsafeContinuation<Void, Never>) in
                    Thread.detachNewThread {
                        Thread.sleep(forTimeInterval: 5)
                        continuation.resume()
                    }
                }
            }
        }

        #expect(ContinuousClock.now - started < .seconds(2), "withTimeout waited for the operation it gave up on")
    }

    /// A task that is *already* cancelled before `withTimeout` is even reached.
    ///
    /// This is not a contrived state. It is what a notification extension is in when iOS
    /// calls `serviceExtensionTimeWillExpire`, and what a SwiftUI `.task` is in the instant
    /// the view goes away — the surrounding task is cancelled, and the work inside it runs
    /// anyway, right up to the first suspension point.
    ///
    /// `withTaskCancellationHandler` runs `onCancel` *immediately* in that case — before the
    /// body has installed its continuation. So `settle` used to take the lock, mark itself
    /// settled, find `continuation == nil`, and resume nothing at all; and every later
    /// arrival — the operation, the timer — then bailed on `guard !settled`. Nobody was ever
    /// resumed, and the caller hung forever. The one thing this file exists to prevent.
    @Test("a caller whose task was already cancelled is released, not hung")
    func alreadyCancelledCallerIsReleased() async {
        let finished = Mutex(false)

        let task = Task {
            // Deliberately deaf to cancellation, so nothing but `withTimeout` can free us.
            try? await withTimeout(.seconds(30)) {
                try? await Task.sleep(for: .seconds(30))
                return 0
            }
            finished.withLock { $0 = true }
        }

        // Cancelled before the body can run. `Task { }` does not start synchronously, so this
        // lands first in practice — and that is exactly the window the bug lived in.
        task.cancel()

        // Bounded, because the whole point is that the unfixed code never comes back: an
        // unguarded `await task.value` here would hang the entire test run rather than fail it.
        _ = try? await withTimeout(.seconds(2)) { await task.value }

        #expect(finished.withLock { $0 }, "withTimeout never resumed a caller that was cancelled before it started")
    }
}
