import Foundation
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
}
