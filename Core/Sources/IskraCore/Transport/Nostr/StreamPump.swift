import Foundation

/// How a stream ended, as far as this side knows.
enum StreamOutcome: Equatable, Sendable {
    /// Both halves closed in order.
    case closed
    /// Reset, with the reason — the other side's word for it when the other side sent it.
    case reset(String)
}

/// Where a stream's frames go: sealed and published to the relays in the app, handed straight to
/// a bridge in the tests. Throws when the frame could not go anywhere at all.
typealias StreamLink = @Sendable (StreamFrame) async throws -> Void

/// One stream, one side: a socket on this end, frames on the other — `pump` in the Rust client.
///
/// Three things run at once, and only one of them is allowed to touch the socket's write half:
///
/// - **sending** reads the socket in segments (`SegmentReader`) while the window is open, and
///   publishes each one. A full window stops the reading, and that is the back-pressure.
/// - **writing** takes what the reassembly has made contiguous, in order, one write at a time, and
///   only then reports it written — the acknowledgement says what the socket *accepted*.
/// - **the watchdog** gives a hole `StreamLimits.gapTimeout` and then resets the stream. There is no
///   retransmission: reqwest sees the reset and retries on a fresh connection.
///
/// The client and the bridge differ only in who sends `open`, so the tests' stand-in bridge runs
/// this same code with `.bridge`, and the questions asked of the protocol are asked of one program.
actor StreamPump {
    enum Role: Sendable {
        /// This side opens: the first segment goes out as `open`, to `host:port`.
        case client(host: String, port: UInt16)
        /// The other side opened; its `open` arrives through `deliver` like any frame.
        case bridge
    }

    let sid: String
    private let role: Role
    private let socket: LocalSocket
    private let reader: SegmentReader
    private let link: StreamLink
    private let maximumSegment: Int

    private var inbound = StreamInbound()
    private var outbound = StreamOutbound()
    /// Our `fin` has gone out.
    private var localDone = false
    /// Their `fin` has been met and the socket's write half closed after the last byte.
    private var remoteDone = false
    /// Their stream is complete and the end has been queued behind the last write.
    private var endQueued = false

    private var outcome: StreamOutcome?
    private var finished: CheckedContinuation<StreamOutcome, Never>?
    private var windowWaiter: CheckedContinuation<Void, Never>?
    private var tasks: [Task<Void, Never>] = []

    private enum Write { case bytes(Data), end }
    private let writes: AsyncStream<Write>
    private let writesIn: AsyncStream<Write>.Continuation

    init(sid: String, role: Role, socket: LocalSocket, leftover: Data = Data(),
         link: @escaping StreamLink, maximumSegment: Int = StreamFrame.defaultSegment) {
        self.sid = sid
        self.role = role
        self.socket = socket
        self.reader = SegmentReader(socket, leftover: leftover)
        self.link = link
        self.maximumSegment = maximumSegment
        (writes, writesIn) = AsyncStream.makeStream(of: Write.self)
    }

    /// Run the stream to its end.
    func run() async -> StreamOutcome {
        tasks.append(Task { await self.sendLoop() })
        tasks.append(Task { await self.writeLoop() })
        tasks.append(Task { await self.watch() })
        return await withCheckedContinuation { continuation in
            if let outcome { continuation.resume(returning: outcome) } else { finished = continuation }
        }
    }

    /// One frame from the other side, already validated.
    func deliver(_ frame: StreamFrame) async {
        guard outcome == nil else { return }
        let now = ContinuousClock.now
        do {
            switch frame.op {
            case .opened:
                break
            case .open:
                // Only ever sent by a client. A copy from a second relay is ordinary, and lands as
                // the duplicate of segment 0 it is.
                guard case .bridge = role else { return reset(StreamReason.protocol) }
                try take(0, frame.payload, now: now)
            case .data:
                try take(frame.seq ?? 0, frame.payload, now: now)
            case .fin:
                _ = try inbound.finish(frame.seq ?? 0, now: now)
            case .ack:
                try outbound.ack(frame.ack ?? 0)
                if outbound.hasRoom(maximumSegment) { resumeWindow() }
            case .rst:
                return end(.reset(frame.reason ?? ""))
            }
        } catch let violation as StreamViolation {
            return reset(violation.reason)
        } catch {
            // Not base64.
            return reset(StreamReason.protocol)
        }
        if inbound.isComplete, !endQueued {
            endQueued = true
            writesIn.yield(.end)
        }
    }

    private func take(_ seq: UInt32, _ bytes: Data, now: ContinuousClock.Instant) throws(StreamViolation) {
        for segment in try inbound.accept(seq, bytes, now: now) {
            writesIn.yield(.bytes(segment))
        }
    }

    // MARK: - The three loops

    private func sendLoop() async {
        if case let .client(host, port) = role {
            // Nothing goes out until the client says something: its first bytes ride in the `open`.
            guard case let .segment(first) = await reader.next(maximum: maximumSegment) else {
                return end(.closed)
            }
            guard await send(.open(sid, host: host, port: port, first: first)) else { return }
            outbound = .afterOpen(first.count)
        }
        while outcome == nil {
            while outcome == nil, !outbound.hasRoom(maximumSegment) {
                await withCheckedContinuation { windowWaiter = $0 }
            }
            guard outcome == nil else { return }
            switch await reader.next(maximum: maximumSegment) {
            case .segment(let bytes):
                guard outcome == nil else { return }
                let seq = outbound.push(bytes.count)
                guard await send(.data(sid, seq: seq, bytes: bytes)) else { return }
            case .end:
                guard outcome == nil, await send(.fin(sid, seq: outbound.nextSeq)) else { return }
                localDone = true
                if remoteDone { end(.closed) }
                return
            case .failed:
                return reset(StreamReason.closed)
            }
        }
    }

    private func writeLoop() async {
        for await write in writes {
            switch write {
            case .bytes(let bytes):
                do {
                    try await socket.send(bytes)
                } catch {
                    return reset(StreamReason.closed)
                }
                await wrote(bytes.count)
            case .end:
                await socket.finishWriting()
                remoteDone = true
                if localDone { end(.closed) }
                return
            }
        }
    }

    private func watch() async {
        while outcome == nil {
            try? await Task.sleep(for: .milliseconds(250))
            if outcome == nil, inbound.gapExpired(now: .now) {
                reset(StreamReason.gap)
            }
        }
    }

    private func wrote(_ count: Int) async {
        if let ack = inbound.written(segments: 1, bytes: count) {
            _ = await send(.ack(sid, ack))
        }
    }

    // MARK: - Ending

    /// Publish one frame. A frame that cannot go anywhere ends the stream: the far side will never
    /// hear the rest of it.
    private func send(_ frame: StreamFrame) async -> Bool {
        do {
            try await link(frame)
            return true
        } catch {
            end(.reset(StreamReason.unreachable))
            return false
        }
    }

    /// End the stream and tell the other side why.
    private func reset(_ reason: String) {
        guard outcome == nil else { return }
        let frame = StreamFrame.rst(sid, reason: reason)
        let link = self.link
        Task { try? await link(frame) }
        end(.reset(reason))
    }

    private func end(_ how: StreamOutcome) {
        guard outcome == nil else { return }
        outcome = how
        for task in tasks { task.cancel() }
        writesIn.finish()
        if case .closed = how { socket.close() } else { socket.reset() }
        resumeWindow()
        finished?.resume(returning: how)
        finished = nil
    }

    private func resumeWindow() {
        let waiter = windowWaiter
        windowWaiter = nil
        waiter?.resume()
    }
}

/// Every stream of one tunnel, keyed by stream id: frames in from one dispatcher, sockets in from
/// the listener.
actor StreamCarrier {
    private let link: StreamLink
    private let maximumSegment: Int
    private var pumps: [String: StreamPump] = [:]

    init(link: @escaping StreamLink, maximumSegment: Int = StreamFrame.defaultSegment) {
        self.link = link
        self.maximumSegment = maximumSegment
    }

    var open: Int { pumps.count }

    /// Run one stream to `host:port` to its end. The stream id is a fresh UUID, chosen here: it is
    /// a key the bridge holds, and it is the client's to choose.
    func carry(_ socket: LocalSocket, host: String, port: UInt16, leftover: Data) async -> StreamOutcome {
        let sid = UUID().uuidString.lowercased()
        return await run(StreamPump(sid: sid, role: .client(host: host, port: port), socket: socket,
                                    leftover: leftover, link: link, maximumSegment: maximumSegment))
    }

    private func run(_ pump: StreamPump) async -> StreamOutcome {
        pumps[pump.sid] = pump
        let outcome = await pump.run()
        pumps[pump.sid] = nil
        return outcome
    }

    /// A frame for one of the streams. A frame for a stream that is not here — over, or never ours
    /// — is dropped: late copies from slow relays are ordinary.
    func deliver(_ frame: StreamFrame) async {
        await pumps[frame.sid]?.deliver(frame)
    }
}
