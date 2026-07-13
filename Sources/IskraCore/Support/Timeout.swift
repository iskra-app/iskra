import Foundation
import Synchronization

/// The operation did not answer inside its limit.
public struct TimeoutError: Error, Equatable {
    public let limit: Duration
}

/// Who won the race. A `Mutex` guards it so that exactly one of them does.
private struct TimeoutState<Value: Sendable> {
    var continuation: CheckedContinuation<Value, any Error>?
    var work: Task<Void, Never>?
    var settled = false
}

/// Runs `operation`, and gives up on it after `limit`.
///
/// The loser is cancelled but deliberately **not awaited**. That is the whole point:
/// this exists to bound a call that might never come back, so it cannot be built on the
/// assumption that the call notices it has been cancelled. A `withThrowingTaskGroup`
/// would read more idiomatically and would quietly do nothing here — a group waits for
/// its children before it returns, so an operation that ignores cancellation would still
/// hold the caller forever, which is the exact bug this is here to prevent.
///
/// The timer task outlives a fast success by up to `limit`. It is a sleeping task that
/// resumes nothing, and racing to cancel it would cost more than it saves.
public func withTimeout<T: Sendable>(
    _ limit: Duration,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let state = Mutex(TimeoutState<T>())

    // Whoever gets here first owns the result; everyone after is ignored, so the
    // continuation is resumed exactly once.
    let settle: @Sendable (Result<T, any Error>) -> Void = { result in
        let continuation = state.withLock { state -> CheckedContinuation<T, any Error>? in
            guard !state.settled else { return nil }
            state.settled = true
            return state.continuation
        }
        continuation?.resume(with: result)
    }

    let abandonWork: @Sendable () -> Void = {
        state.withLock { $0.work }?.cancel()
    }

    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, any Error>) in
            // Attached before the work starts, and in that order: a fast operation could
            // otherwise finish and settle into a continuation that is not there yet, and
            // the caller would wait forever — the very bug this is fixing.
            state.withLock { $0.continuation = continuation }

            let work = Task {
                do { settle(.success(try await operation())) }
                catch { settle(.failure(error)) }
            }
            state.withLock { $0.work = work }

            Task {
                try? await Task.sleep(for: limit)
                settle(.failure(TimeoutError(limit: limit)))
                abandonWork()
            }
        }
    } onCancel: {
        settle(.failure(CancellationError()))
        abandonWork()
    }
}
