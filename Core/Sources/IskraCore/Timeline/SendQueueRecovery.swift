import Foundation

/// When to start a room's send queue again after it has stopped itself — the half of Telegram's
/// `PendingMessageManager` that the SDK leaves to us.
///
/// The SDK's send queue already does the other half, and does it well: a message is written into
/// the encrypted store before anything is attempted, it survives the app being killed, and it goes
/// out in order. What it does *not* do is try again. A request that fails for a reason that may pass
/// — no network, a server timing out, a 502 from a proxy in front of it — is called *recoverable*,
/// and the SDK answers it by disabling that room's queue and waiting to be told to carry on. Nothing
/// told it, except sync coming back (`RoomListStore.syncStateChanged`), and sync does not go away
/// for a server that is merely refusing sends. So a message written into a flaky connection sat
/// there until the next time the network dropped *completely* and came back — which on a good Wi-Fi
/// is never.
///
/// Telegram never asks: an outgoing message waits with a clock, and goes when it can. So this does
/// the same — every time a queue stops itself, it is started again after a pause that doubles with
/// each failure in a row, and the run of failures is forgotten once the queue has kept quiet for a
/// while. Offline there is nothing to wait for: sync reports the network back and starts every queue
/// at once, which is sooner than any backoff could be.
///
/// A value type, kept apart from `RoomListStore` so the arithmetic can be pinned by a test without a
/// client to drive it.
struct SendQueueRecovery: Equatable, Sendable {
    /// How many times in a row the queues have stopped, each too soon after the last to have been
    /// a separate trouble.
    private(set) var failuresInARow = 0

    /// When the last stop was, so that the next one can tell whether it belongs to the same run.
    private(set) var lastFailure: Date?

    /// A queue has stopped. Returns how long to wait before starting it again.
    mutating func failed(at now: Date = .now) -> Duration {
        if let lastFailure, now.timeIntervalSince(lastFailure) > Self.quietPeriod {
            failuresInARow = 0
        }
        lastFailure = now
        failuresInARow += 1

        // 1, 2, 4, 8, 16, 30, 30… seconds. The first is short because the ordinary cause is a single
        // dropped request on a connection that is otherwise fine; the ceiling is low because a person
        // is looking at a clock beside their message, and half a minute is already a long time to
        // look at one.
        let seconds = min(Self.ceiling, pow(2, Double(failuresInARow - 1)))
        return .seconds(seconds)
    }

    /// The queues went quiet for long enough that the next failure is a new trouble, not the same
    /// one — or the network came back, which is a fresh start by definition.
    mutating func reset() {
        failuresInARow = 0
        lastFailure = nil
    }

    /// Longest pause between attempts, in seconds.
    static let ceiling: Double = 30

    /// How long without a failure before the run is considered over, in seconds. Longer than the
    /// ceiling, so a queue failing on every attempt at the ceiling never looks quiet.
    static let quietPeriod: TimeInterval = 60
}
