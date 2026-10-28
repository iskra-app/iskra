import Foundation
import Network

/// One TCP connection, as bytes: what `LocalConnectProxy` hands to whatever carries it onward.
///
/// `NWConnection` predates strict concurrency and is not `Sendable`, while a stream reads it in one
/// task and writes it in another. It is safe to: the class is documented as thread-safe, and every
/// call made here is one of the ones that are.
final class LocalSocket: @unchecked Sendable {
    private let connection: NWConnection

    init(_ connection: NWConnection) {
        self.connection = connection
    }

    /// A connection out to `host:port`, not yet started.
    convenience init?(host: String, port: UInt16) {
        guard let port = NWEndpoint.Port(rawValue: port) else { return nil }
        self.init(NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp))
    }

    /// Start, and say whether the connection came up.
    func start() async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let resumed = ResumeOnceValue<Bool>(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: resumed.finish(true)
                case .failed, .cancelled: resumed.finish(false)
                // A connection out that is waiting for a route is a connection that failed, as far
                // as somebody waiting on it is concerned.
                case .waiting: resumed.finish(false)
                default: break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
        }
    }

    /// The next bytes, as many as have arrived up to `maximum`. Nil once the other side has closed
    /// its half.
    func receive(maximum: Int = 64 * 1024) async throws -> Data? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, Error>) in
            let resumed = ResumeOnce(continuation)
            connection.receive(minimumIncompleteLength: 1, maximumLength: maximum) { data, _, isComplete, error in
                // The end before the error: a half-closed connection can report its end-of-stream
                // as `ENODATA`, and read as a failure that is a reset of a stream that ended in
                // order.
                if let data, !data.isEmpty {
                    resumed.succeed(data)
                } else if isComplete || error == .posix(.ENODATA) {
                    resumed.succeed(nil)
                } else if let error {
                    resumed.fail(error)
                } else {
                    resumed.succeed(Data())
                }
            }
        }
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let resumed = ResumeOnce(continuation)
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { resumed.fail(error) } else { resumed.succeed() }
            })
        }
    }

    /// Close this side's half: the other end reads end-of-stream, and may still write.
    func finishWriting() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumed = ResumeOnceValue<Void>(continuation)
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                            completion: .contentProcessed { _ in resumed.finish() })
        }
    }

    /// Close, in order.
    func close() {
        connection.cancel()
    }

    /// Close at once, so that the other end sees a reset rather than an ordinary end — which is
    /// what makes reqwest retry the request on a fresh connection instead of reading a short answer.
    func reset() {
        connection.forceCancel()
    }

    /// This end's port, once connected. How a test tells which connections a listener was handed
    /// came out of the pipe it was supposed to come through.
    var localPort: UInt16? {
        guard case let .hostPort(_, port) = connection.currentPath?.localEndpoint else { return nil }
        return port.rawValue
    }

    var remotePort: UInt16? {
        guard case let .hostPort(_, port) = connection.currentPath?.remoteEndpoint ?? connection.endpoint else {
            return nil
        }
        return port.rawValue
    }
}

/// A socket read in segments: what arrives without a pause, up to a size — `next_segment` in the
/// Rust client, the same rule.
///
/// The coalescing is the point. A socket hands TLS records over a few hundred bytes at a time, and
/// one event per read would be hundreds of events per room load and a ban from a volunteer's relay.
/// So a segment goes once `maximum` has gathered or the socket has been quiet for
/// `StreamLimits.coalesce`.
///
/// Reading ahead is bounded by `readAhead`: past it nothing more is asked of the socket until the
/// owner takes what is there. That is what lets a full window stop the reading, and TCP carry the
/// back-pressure to whoever is writing.
actor SegmentReader {
    enum Read: Equatable {
        case segment(Data)
        case end
        case failed
    }

    private let socket: LocalSocket
    private let readAhead: Int
    private var buffer: Data
    private var ended = false
    private var failed = false
    private var reading: Task<Void, Never>?
    private var waiting: CheckedContinuation<Void, Never>?

    init(_ socket: LocalSocket, leftover: Data = Data(), readAhead: Int = 64 * 1024) {
        self.socket = socket
        self.buffer = leftover
        self.readAhead = readAhead
    }

    func next(maximum: Int, coalesce: Duration = StreamLimits.coalesce) async -> Read {
        readMore()
        while buffer.isEmpty, !ended, !failed, !Task.isCancelled {
            await withCheckedContinuation { waiting = $0 }
        }
        if buffer.isEmpty { return failed || !ended ? .failed : .end }

        while buffer.count < maximum, !ended, !failed, !Task.isCancelled {
            let before = buffer.count
            readMore()
            try? await Task.sleep(for: coalesce)
            if buffer.count == before { break }
        }
        let take = min(maximum, buffer.count)
        let segment = Data(buffer.prefix(take))
        buffer.removeFirst(take)
        readMore()
        return .segment(segment)
    }

    /// Ask the socket for more, unless a read is already out or enough is already here.
    private func readMore() {
        guard reading == nil, !ended, !failed, buffer.count < readAhead else { return }
        let socket = self.socket
        reading = Task { [weak self] in
            do {
                let data = try await socket.receive()
                await self?.received(data)
            } catch {
                await self?.broke()
            }
        }
    }

    private func received(_ data: Data?) {
        reading = nil
        if let data { buffer.append(data) } else { ended = true }
        wake()
        readMore()
    }

    private func broke() {
        reading = nil
        failed = true
        wake()
    }

    private func wake() {
        let waiter = waiting
        waiting = nil
        waiter?.resume()
    }
}
