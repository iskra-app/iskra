import Foundation
import Network

/// A minimal HTTP/1.1 server on `127.0.0.1`, which the Matrix SDK is pointed at as if it were the
/// homeserver.
///
/// Why a listener and not `ClientBuilder.proxy(_:)`: a homeserver is `https`, so reqwest would send
/// the proxy `CONNECT matrix.org:443` and then run TLS end to end through it. A proxy would see
/// ciphertext and have nothing to wrap in a nostr event. Pointing `homeserverUrl` at plain HTTP on
/// loopback instead puts the requests in front of us in the clear, with the real TLS terminated at
/// the bridge, and needs no interception certificate and no `disableSslVerification()`.
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
    /// Told where the homeserver really lives, once `.well-known` says so. The upstream is told
    /// too, but it is not the only one who needs to know: the address that gets written into the
    /// Keychain has to be the real one, not this listener's.
    private let onDiscovery: (@Sendable (URL) -> Void)?
    private var listener: NWListener?
    private var boundPort: UInt16?
    /// Set by `stop()`, and only by it: a listener that ends while this is false was taken away, and
    /// is raised again. See `ensureListening`.
    private var stopped = false

    /// Requests seen, newest last. Diagnostics for the probe: proof that the SDK really came
    /// through here rather than reaching the homeserver some other way.
    private var seen: [ProxiedRequest] = []

    public init(upstream: HTTPUpstream, onDiscovery: (@Sendable (URL) -> Void)? = nil) {
        self.upstream = upstream
        self.onDiscovery = onDiscovery
    }

    public var port: UInt16? { boundPort }
    public var requestLog: [ProxiedRequest] { seen }

    /// The address to hand to `ClientBuilder.homeserverUrl(url:)`.
    public var homeserverURL: String? {
        boundPort.map { "http://127.0.0.1:\($0)" }
    }

    /// Bind, and return the port the system chose.
    ///
    /// The port is asked for rather than picked: a hard-coded one is taken sooner or later, and on
    /// a phone the failure would look like the tunnel being broken.
    @discardableResult
    public func start() async throws -> UInt16 {
        stopped = false
        let port = try await bind(port: .any)
        boundPort = port
        return port
    }

    public func stop() {
        stopped = true
        let listener = self.listener
        self.listener = nil
        listener?.cancel()
        boundPort = nil
    }

    /// Make sure the listener is still there, and raise it again on the same port if it is not.
    ///
    /// **iOS takes listening sockets away from a suspended app.** It is documented behaviour
    /// (TN2277, "socket resource reclaim"), and it is invisible from the outside: the app comes back
    /// from the background, the listener it raised at launch is gone, and the SDK — which knows the
    /// homeserver only as `http://127.0.0.1:<that port>` — gets its connections refused and reports
    /// that there is no network. Which is what it did, on a phone, every time the app had been in a
    /// pocket long enough, while the bridge on the far side answered perfectly well.
    ///
    /// The listener's own state handler notices a reclaim when the app wakes and rebinds on its
    /// own; this is the same thing asked for deliberately, from `UserSession.enteredForeground`,
    /// *before* sync starts again — so that the first request after a wake is not the one that
    /// finds the port closed.
    public func ensureListening() async {
        guard !stopped, boundPort != nil else { return }
        if let listener, listener.state == .ready { return }
        await relisten()
    }

    /// What a reclaim looks like from the inside: the socket goes without anybody calling `stop()`.
    /// For tests, which cannot suspend a process to make iOS do it.
    func simulateReclaim() {
        listener?.cancel()
    }

    private func bind(port requested: NWEndpoint.Port) async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: requested)
        parameters.allowLocalEndpointReuse = true

        let listener = try NWListener(using: parameters)
        self.listener = listener

        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            Task { await self.accept(connection) }
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let resumed = ResumeOnce(continuation)
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready: resumed.succeed()
                // After `.ready` there is nobody waiting on the continuation, and a failure is not
                // a failure to start — it is the listener being lost, which used to be ignored
                // here. That silence was the whole of the "no network after the background" bug.
                case .failed(let error):
                    if !resumed.fail(error) { Task { await self?.lost(listener) } }
                case .cancelled:
                    if !resumed.fail(ProxyError.notStarted) { Task { await self?.lost(listener) } }
                default: break
                }
            }
            listener.start(queue: .global(qos: .userInitiated))
        }

        guard let port = listener.port?.rawValue else { throw ProxyError.notStarted }
        return port
    }

    /// A listener went away without `stop()` being called.
    private func lost(_ listener: NWListener) async {
        // Only the current one matters: a listener already replaced, or one cancelled by `stop()`,
        // reports its own end too, and must not start a second rebind.
        guard !stopped, listener === self.listener else { return }
        Log.session.warning("the local listener was lost; raising it again on the same port")
        await relisten()
    }

    /// Bind again on the port the SDK already knows. A new port would be no use: the client was
    /// built with the old one and cannot be told another.
    private func relisten() async {
        guard !stopped, let port = boundPort, let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        let previous = listener
        listener = nil
        previous?.cancel()

        // A few tries, because the port can take a moment to be free again after a reclaim.
        for attempt in 1...5 {
            guard !stopped else { return }
            do {
                _ = try await bind(port: nwPort)
                return
            } catch {
                Log.session.warning("the listener would not come back (try \(attempt)): \(Log.describe(error), privacy: .public)")
                try? await Task.sleep(for: .milliseconds(200 * attempt))
            }
        }
    }

    private func accept(_ connection: NWConnection) {
        let upstream = self.upstream
        let localBase = homeserverURL
        let onDiscovery = self.onDiscovery
        Task.detached(priority: .userInitiated) { [weak self] in
            let channel = HTTPChannel(connection: connection)
            await channel.start()
            while let request = try? await channel.readRequest() {
                await self?.record(request)
                var response: ProxiedResponse
                do {
                    response = try await upstream.send(request)
                } catch {
                    // The SDK is owed an answer even when there is none to give. Silence would
                    // leave it waiting out its own timeout with nothing to explain it.
                    response = ProxiedResponse(status: 502)
                }
                if let localBase {
                    let (rewritten, discovered) = Self.keepDiscoveryHome(
                        request, response, localBase: localBase
                    )
                    response = rewritten
                    if let discovered {
                        await upstream.discovered(homeserver: discovered)
                        onDiscovery?(discovered)
                    }
                }
                guard await channel.write(response) else { break }
            }
            await channel.close()
        }
    }

    /// Point `.well-known` discovery back at this listener.
    ///
    /// Without this the tunnel leaks on the one path that matters most, and it does it silently.
    /// Sign-in goes through `serverNameOrHomeserverUrl`, which asks the server name for
    /// `/.well-known/matrix/client`; matrix.org answers with an absolute
    /// `https://matrix-client.matrix.org`, the SDK believes it, and **every request after that goes
    /// straight to the homeserver** — bypassing the tunnel completely while the app shows a working
    /// connection. Measured, not guessed: `client.homeserver()` came back as
    /// `https://matrix-client.matrix.org/` before this existed.
    ///
    /// So the discovered base URL is rewritten to us, and the bridge resolves the real one.
    /// `m.identity_server` is deliberately left alone — it names a different host and is not
    /// something this bridge fronts, so pointing it here would break it rather than tunnel it.
    /// - Returns: the answer to hand back, and the homeserver discovery named, if it named one.
    ///   The caller passes that second value to the upstream so later requests go to the host the
    ///   API actually lives on.
    static func keepDiscoveryHome(
        _ request: ProxiedRequest,
        _ response: ProxiedResponse,
        localBase: String
    ) -> (ProxiedResponse, URL?) {
        guard request.target.hasPrefix("/.well-known/matrix/client"),
              response.status == 200,
              var document = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
              var homeserver = document["m.homeserver"] as? [String: Any]
        else { return (response, nil) }

        let discovered = (homeserver["base_url"] as? String).flatMap(URL.init(string:))

        homeserver["base_url"] = localBase
        document["m.homeserver"] = homeserver

        guard let rewritten = try? JSONSerialization.data(withJSONObject: document) else {
            return (response, discovered)
        }
        var response = response
        response.body = rewritten
        return (response, discovered)
    }

    private func record(_ request: ProxiedRequest) {
        seen.append(request)
    }
}

/// One TCP connection, spoken to in HTTP/1.1.
///
/// Keep-alive is not optional here: reqwest pools connections and will send many requests down one
/// of them, so a server that closes after each response makes every request pay for a new socket.
private actor HTTPChannel {
    private let connection: NWConnection
    private var buffer = Data()
    private var closed = false

    init(connection: NWConnection) {
        self.connection = connection
    }

    func start() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumed = ResumeOnceVoid(continuation)
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

        let body: Data
        if let length = headers.first(where: { $0.key.lowercased() == "content-length" })?.value,
           let expected = Int(length), expected > 0 {
            body = try await read(exactly: expected)
        } else if headers.contains(where: {
            $0.key.lowercased() == "transfer-encoding" && $0.value.lowercased().contains("chunked")
        }) {
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
            let resumed = ResumeOnceBool(continuation)
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
            try await fill()
        }
    }

    private func read(exactly count: Int) async throws -> Data {
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
            guard let size else {
                throw LocalHTTPProxy.ProxyError.malformedRequest("chunk size: \(line)")
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
                return String(decoding: line, as: UTF8.self)
            }
            try await fill()
        }
    }

    private func fill() async throws {
        let chunk: Data = try await withCheckedThrowingContinuation { continuation in
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
        buffer.append(chunk)
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

// MARK: - Continuation guards
//
// Network.framework handlers can fire more than once (a state handler certainly does), and
// resuming a continuation twice is a crash, not a warning. These make "first one wins" explicit.

private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    func succeed(_ value: T) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }

    /// Whether this was the call that resumed — `false` when somebody already had, which is how a
    /// state handler tells "failed to start" from "failed later".
    @discardableResult
    func fail(_ error: Error) -> Bool {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(throwing: error)
        return pending != nil
    }
}

extension ResumeOnce where T == Void {
    func succeed() { succeed(()) }
}

private final class ResumeOnceVoid: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?

    init(_ continuation: CheckedContinuation<Void, Never>) {
        self.continuation = continuation
    }

    func finish() {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume()
    }
}

private final class ResumeOnceBool: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?

    init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func finish(_ value: Bool) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}
