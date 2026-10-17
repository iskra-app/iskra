import Foundation
import Network

/// A minimal HTTP/1.1 server on `127.0.0.1`, which the Matrix SDK is pointed at as if it were the
/// homeserver — for the homeservers that live inside the app: the demo server and the sign-in
/// server, each an `HTTPUpstream` answered in process.
///
/// It used to front the bridge as well, and that was the bridge's flaw rather than this listener's:
/// requests arrived here in the clear so that they could be handed on, token and all. The bridge now
/// carries the SDK's own TLS through `LocalConnectProxy`, and nothing real comes through here.
///
/// Bound to loopback explicitly. A listener on `0.0.0.0` would be an open unauthenticated proxy to
/// someone's homeserver session, reachable by anything on the same Wi-Fi.
public actor LocalHTTPProxy {
    public enum ProxyError: Error, Sendable {
        case notStarted
        case malformedRequest(String)
        /// The client opened an HTTP/2 prior-knowledge connection, which this server does not speak.
        case unexpectedHTTP2
    }

    private let upstream: HTTPUpstream
    /// Kept separately from the listener because it never changes once bound: a listener taken
    /// away by the system is raised again on the same port (see `LoopbackListener`).
    private var boundPort: UInt16?
    private var listener: LoopbackListener?
    /// Only the tests' homeserver has one. See `LoopbackListener.init`.
    private let tls: TLSIdentity?

    /// Requests seen, newest last — the method and the path, nothing else, and only the last few
    /// hundred. Diagnostics for the probe: proof that the SDK really came through here rather than
    /// reaching the homeserver some other way.
    ///
    /// It used to keep every request whole, for the life of the session: every `Authorization:
    /// Bearer`, the password in `/login`, every photo uploaded — memory that only grew, and a
    /// plaintext copy of the token that nothing else needed.
    private var seen: [ProxiedRequest] = []
    private static let seenLimit = 256

    public init(upstream: HTTPUpstream) {
        self.init(upstream: upstream, tls: nil)
    }

    init(upstream: HTTPUpstream, tls: TLSIdentity?) {
        self.upstream = upstream
        self.tls = tls
    }

    public var port: UInt16? { boundPort }
    public var requestLog: [ProxiedRequest] { seen }

    /// A request of the app's own, sent to whatever stands behind this listener without a round
    /// trip through the socket — for the few calls the SDK does not export (`AccountDevices`), so
    /// that the screens built on them work in the demo too. In process rather than over
    /// `http://127.0.0.1`, because App Transport Security would have its say about plain HTTP.
    public func forward(_ request: ProxiedRequest) async throws -> ProxiedResponse {
        try await upstream.send(request)
    }

    /// The address to hand to `ClientBuilder.homeserverUrl(url:)`.
    public var homeserverURL: String? {
        boundPort.map { "\(tls == nil ? "http" : "https")://127.0.0.1:\($0)" }
    }

    /// Bind, and return the port the system chose.
    @discardableResult
    public func start() async throws -> UInt16 {
        let listener = self.listener ?? LoopbackListener(tls: tls) { [weak self] connection in
            Task { await self?.accept(connection) }
        }
        self.listener = listener
        let port = try await listener.start()
        boundPort = port
        return port
    }

    public func stop() async {
        boundPort = nil
        await listener?.stop()
    }

    /// Make sure the listener is still there, and raise it again on the same port if it is not —
    /// see `LoopbackListener`, which this and `LocalConnectProxy` share.
    public func ensureListening() async {
        await listener?.ensureListening()
    }

    /// What a reclaim looks like from the inside. For tests.
    func simulateReclaim() async {
        await listener?.simulateReclaim()
    }

    /// The far-end port of every connection accepted, newest last, bounded like `seen`. For the
    /// tests of the blind route, which hold these against the ports `DirectPipe` connected from:
    /// a connection here that the pipe did not make is a request that went around the proxy.
    private(set) var peerPorts: [UInt16] = []

    private func accept(_ connection: NWConnection) {
        if case let .hostPort(_, port) = connection.endpoint {
            peerPorts.append(port.rawValue)
            if peerPorts.count > Self.seenLimit { peerPorts.removeFirst(peerPorts.count - Self.seenLimit) }
        }
        let upstream = self.upstream
        Task.detached(priority: .userInitiated) { [weak self] in
            let channel = HTTPChannel(connection: connection)
            await channel.start()
            while let request = try? await channel.readRequest() {
                await self?.record(request)
                let response: ProxiedResponse
                do {
                    response = try await upstream.send(request)
                } catch {
                    // The SDK is owed an answer even when there is none to give. Silence would
                    // leave it waiting out its own timeout with nothing to explain it.
                    response = ProxiedResponse(status: 502)
                }
                guard await channel.write(response) else { break }
            }
            await channel.close()
        }
    }

    private func record(_ request: ProxiedRequest) {
        seen.append(ProxiedRequest(method: request.method, target: request.target))
        if seen.count > Self.seenLimit { seen.removeFirst(seen.count - Self.seenLimit) }
    }
}

/// One TCP connection, spoken to in HTTP/1.1.
///
/// Keep-alive is not optional here: reqwest pools connections and will send many requests down one
/// of them, so a server that closes after each response makes every request pay for a new socket.
private actor HTTPChannel {
    /// The ceilings on what a connection may make this process hold. The listener is on loopback,
    /// but loopback is every process on the machine — on a Mac, every user's — and without these an
    /// endless header or a `Content-Length` of a terabyte was the app growing until the system
    /// killed it.
    ///
    /// The body ceiling is the largest thing this app would ever upload with room to spare —
    /// Synapse's default upload limit is 50 MB, and a bridge carries at most 8.
    static let maxHead = 64 * 1024
    static let maxLine = 8 * 1024
    static let maxBody = 128 * 1024 * 1024
    static let idleLimit: Duration = .seconds(120)

    private let connection: NWConnection
    private var buffer = Data()
    private var closed = false

    init(connection: NWConnection) {
        self.connection = connection
    }

    func start() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumed = ResumeOnceValue<Void>(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready, .failed, .cancelled: resumed.finish()
                default: break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        connection.cancel()
    }

    func readRequest() async throws -> ProxiedRequest {
        let head = try await readUntilHeadEnd()
        guard let headText = String(data: head, encoding: .utf8) else {
            throw LocalHTTPProxy.ProxyError.malformedRequest("head is not UTF-8")
        }

        var lines = headText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first, !requestLine.isEmpty else {
            throw LocalHTTPProxy.ProxyError.malformedRequest("empty request line")
        }
        // `PRI * HTTP/2.0` is the HTTP/2 prior-knowledge preface. Recognised by name so the failure
        // says what happened instead of "malformed request".
        if requestLine.hasPrefix("PRI * HTTP/2.0") {
            throw LocalHTTPProxy.ProxyError.unexpectedHTTP2
        }
        lines.removeFirst()

        let parts = requestLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2 else {
            throw LocalHTTPProxy.ProxyError.malformedRequest("request line: \(requestLine)")
        }
        let method = String(parts[0])
        let target = String(parts[1])

        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        let lengths = headers.filter { $0.key.lowercased() == "content-length" }.map(\.value)
        let chunked = headers.contains {
            $0.key.lowercased() == "transfer-encoding" && $0.value.lowercased().contains("chunked")
        }
        // Both at once is the shape of request smuggling, and nothing honest sends it.
        if chunked, !lengths.isEmpty {
            throw LocalHTTPProxy.ProxyError.malformedRequest("both Content-Length and chunked")
        }

        let body: Data
        if let length = lengths.first {
            guard let expected = Int(length), expected >= 0, expected <= Self.maxBody else {
                throw LocalHTTPProxy.ProxyError.malformedRequest("content length")
            }
            body = expected > 0 ? try await read(exactly: expected) : Data()
        } else if chunked {
            body = try await readChunkedBody()
        } else {
            body = Data()
        }

        return ProxiedRequest(method: method, target: target, headers: headers, body: body)
    }

    /// Returns false when the connection could not be written to, so the caller stops.
    func write(_ response: ProxiedResponse) async -> Bool {
        var head = "HTTP/1.1 \(response.status) \(Self.reason(for: response.status))\r\n"
        for (name, value) in response.headers where name.lowercased() != "content-length" {
            head += "\(name): \(value)\r\n"
        }
        head += "Content-Length: \(response.body.count)\r\n"
        head += "Connection: keep-alive\r\n\r\n"

        var payload = Data(head.utf8)
        payload.append(response.body)

        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let resumed = ResumeOnceValue<Bool>(continuation)
            connection.send(content: payload, completion: .contentProcessed { error in
                resumed.finish(error == nil)
            })
        }
    }

    private func readUntilHeadEnd() async throws -> Data {
        let terminator = Data("\r\n\r\n".utf8)
        while true {
            if let range = buffer.range(of: terminator) {
                let head = buffer[buffer.startIndex..<range.lowerBound]
                buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                return Data(head)
            }
            guard buffer.count <= Self.maxHead else {
                throw LocalHTTPProxy.ProxyError.malformedRequest("head too large")
            }
            try await fill()
        }
    }

    private func read(exactly count: Int) async throws -> Data {
        // `prefix` traps on a negative count, and this count is a number off the wire.
        guard count >= 0 else { throw LocalHTTPProxy.ProxyError.malformedRequest("negative length") }
        while buffer.count < count {
            try await fill()
        }
        let body = buffer.prefix(count)
        buffer.removeFirst(count)
        return Data(body)
    }

    private func readChunkedBody() async throws -> Data {
        var body = Data()
        while true {
            let line = try await readLine()
            let size = Int(line.split(separator: ";").first.map(String.init) ?? line, radix: 16)
            // `Int("-1", radix: 16)` is -1, which is not 0: any process on the machine could send
            // `-1` as a chunk size and take the app down on `prefix(-1)`.
            guard let size, size >= 0, body.count + size <= Self.maxBody else {
                throw LocalHTTPProxy.ProxyError.malformedRequest("chunk size")
            }
            if size == 0 {
                _ = try? await readLine() // trailing CRLF
                return body
            }
            body.append(try await read(exactly: size))
            _ = try await readLine()
        }
    }

    private func readLine() async throws -> String {
        let terminator = Data("\r\n".utf8)
        while true {
            if let range = buffer.range(of: terminator) {
                let line = Data(buffer[buffer.startIndex..<range.lowerBound])
                buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                return String(bytes: line, encoding: .utf8) ?? ""
            }
            guard buffer.count <= Self.maxLine + Self.maxHead else {
                throw LocalHTTPProxy.ProxyError.malformedRequest("line too long")
            }
            try await fill()
        }
    }

    /// One read, bounded by `idleLimit` — silence, not duration: a slow upload keeps sending and
    /// is never cut off, while a connection that goes quiet is closed. reqwest's pool simply
    /// opens another, and anything else on the machine that connected and said nothing does not
    /// get to hold a task and a socket here for ever.
    private func fill() async throws {
        let connection = self.connection
        let chunk = try await withTimeout(Self.idleLimit) { try await Self.receive(from: connection) }
        buffer.append(chunk)
    }

    private static func receive(from connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let resumed = ResumeOnce(continuation)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                if let error {
                    resumed.fail(error)
                } else if let data, !data.isEmpty {
                    resumed.succeed(data)
                } else if isComplete {
                    resumed.fail(LocalHTTPProxy.ProxyError.malformedRequest("connection closed"))
                } else {
                    resumed.succeed(Data())
                }
            }
        }
    }

    private static func reason(for status: Int) -> String {
        switch status {
        case 200: "OK"
        case 201: "Created"
        case 204: "No Content"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 429: "Too Many Requests"
        case 500: "Internal Server Error"
        case 502: "Bad Gateway"
        default: "Status"
        }
    }
}
