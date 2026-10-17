import Foundation
import Network
import Synchronization

/// What carries a `CONNECT`ed connection onward: the nostr stream tunnel in the app, a plain TCP
/// connection (`DirectPipe`) in the tests.
protocol ConnectUpstream: Sendable {
    /// Carry `socket` to `host:port` until either side is done. `leftover` is whatever the client
    /// sent after its `CONNECT` head without waiting for the `200` — the start of its ClientHello,
    /// usually nothing.
    func carry(_ socket: LocalSocket, host: String, port: UInt16, leftover: Data) async
}

/// The blind bridge's local end: an HTTP proxy on `127.0.0.1` that answers `CONNECT` and nothing
/// else.
///
/// The SDK is built with the *real* homeserver address and this as its proxy
/// (`ClientBuilder.proxy(url:)`). reqwest then does what it does with any `https` address behind an
/// `http` proxy: sends `CONNECT matrix-client.matrix.org:443`, and runs its own TLS through the
/// connection, checking the real certificate. What reaches this listener after the `200` is
/// ciphertext, and ciphertext is exactly what a bridge that must not see should be handed. That is
/// the opposite of why `LocalHTTPProxy` refuses to be a proxy — it needs the requests in the clear —
/// and both are right about what they are for.
///
/// **`Proxy-Authorization` is required.** Anything on the device can knock on a loopback port, and
/// without it this would carry any app's traffic through the user's bridge. The secret is random
/// per listener and lives in the proxy URL (`http://iskra:<secret>@127.0.0.1:<port>`); reqwest puts
/// it in the `CONNECT` head by itself, and a `CONNECT` without it is answered `407`.
///
/// `200` goes back at once, before anything on the far side has said a word: the ClientHello does
/// not come until it has, and the ClientHello is what rides in the `open` — a cold connection would
/// otherwise pay one more round trip through a relay.
actor LocalConnectProxy {
    static let user = "iskra"
    /// The `CONNECT` head is a line and a few headers. A ceiling, because loopback is every process
    /// on the machine.
    static let maxHead = 8 * 1024
    /// And it comes at once, or not at all.
    static let headTimeout: Duration = .seconds(10)

    private let upstream: ConnectUpstream
    private let secret: String
    private var boundPort: UInt16?
    private var listener: LoopbackListener?
    /// `CONNECT`s that were let through.
    private(set) var carried = 0
    /// Connections turned away: no `CONNECT`, or no secret.
    private(set) var refused = 0

    init(upstream: ConnectUpstream, secret: String = LocalConnectProxy.newSecret()) {
        self.upstream = upstream
        self.secret = secret
    }

    /// 32 random bytes, as hex. Lives in memory and in the client's proxy URL, nowhere else.
    static func newSecret() -> String {
        var generator = SystemRandomNumberGenerator()
        return Hex.string(Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }))
    }

    var port: UInt16? { boundPort }

    /// The address to hand to `ClientBuilder.proxy(url:)`.
    var proxyURL: String? {
        boundPort.map { "http://\(Self.user):\(secret)@127.0.0.1:\($0)" }
    }

    /// A `URLSession` that goes through this listener, secret and all — for the app's own requests
    /// (`AccountDevices`) and for `BridgeCheck`, which must travel the way the SDK's do.
    ///
    /// - Parameter delegate: for the tests, whose homeserver has a certificate nobody trusts.
    func urlSession(delegate: URLSessionDelegate? = nil) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        if let boundPort, let port = NWEndpoint.Port(rawValue: boundPort) {
            var proxy = ProxyConfiguration(httpCONNECTProxy: .hostPort(host: "127.0.0.1", port: port))
            proxy.applyCredential(username: Self.user, password: secret)
            configuration.proxyConfigurations = [proxy]
        } else {
            // Not listening: a session with no way out, rather than one that goes direct.
            configuration.proxyConfigurations = [ProxyConfiguration(httpCONNECTProxy: .hostPort(host: "127.0.0.1", port: .any))]
        }
        return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    @discardableResult
    func start() async throws -> UInt16 {
        let listener = self.listener ?? LoopbackListener { [weak self] connection in
            Task { await self?.accept(connection) }
        }
        self.listener = listener
        let port = try await listener.start()
        boundPort = port
        return port
    }

    func stop() async {
        boundPort = nil
        await listener?.stop()
    }

    /// See `LoopbackListener` — the same reclaim, the same cure as `LocalHTTPProxy`'s.
    func ensureListening() async {
        await listener?.ensureListening()
    }

    func simulateReclaim() async {
        await listener?.simulateReclaim()
    }

    private func accept(_ connection: NWConnection) {
        let expected = Data("Basic \(Data("\(Self.user):\(secret)".utf8).base64EncodedString())".utf8)
        let upstream = self.upstream
        Task.detached(priority: .userInitiated) { [weak self] in
            let socket = LocalSocket(connection)
            guard await socket.start() else { return socket.close() }
            switch await Self.readHead(socket) {
            case .none:
                socket.close()
            case let .some((head, leftover)):
                switch Self.answer(head, expected: expected) {
                case let .refuse(response):
                    await self?.count(carried: false)
                    try? await socket.send(Data(response.utf8))
                    socket.close()
                case let .connect(host, port):
                    await self?.count(carried: true)
                    guard (try? await socket.send(Data("HTTP/1.1 200 Connection established\r\n\r\n".utf8))) != nil else {
                        return socket.close()
                    }
                    await upstream.carry(socket, host: host, port: port, leftover: leftover)
                }
            }
        }
    }

    private func count(carried: Bool) {
        if carried { self.carried += 1 } else { refused += 1 }
    }

    /// The head up to its blank line, and whatever came after it.
    private static func readHead(_ socket: LocalSocket) async -> (String, Data)? {
        var buffer = Data()
        let terminator = Data("\r\n\r\n".utf8)
        while true {
            if let range = buffer.range(of: terminator) {
                let head = String(decoding: buffer[buffer.startIndex..<range.lowerBound], as: UTF8.self)
                return (head, Data(buffer[range.upperBound...]))
            }
            guard buffer.count <= maxHead,
                  let chunk = try? await withTimeout(headTimeout, operation: { try await socket.receive() })
            else { return nil }
            buffer.append(chunk)
        }
    }

    enum Answer: Equatable {
        case connect(host: String, port: UInt16)
        case refuse(String)
    }

    /// What to say to a head. Separate from the socket so the refusals can be tested as text.
    static func answer(_ head: String, expected: Data) -> Answer {
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.isEmpty ? "" : lines.removeFirst()
        let parts = requestLine.split(separator: " ")
        guard parts.count == 3, parts[0] == "CONNECT" else {
            return .refuse("HTTP/1.1 405 Method Not Allowed\r\nConnection: close\r\n\r\n")
        }
        let given = lines.lazy
            .compactMap { line -> Substring? in
                guard let colon = line.firstIndex(of: ":"),
                      line[..<colon].trimmingCharacters(in: .whitespaces).lowercased() == "proxy-authorization"
                else { return nil }
                return line[line.index(after: colon)...]
            }
            .first
            .map { Data($0.trimmingCharacters(in: .whitespaces).utf8) }
        guard let given, constantTimeEqual(given, expected) else {
            return .refuse("HTTP/1.1 407 Proxy Authentication Required\r\n"
                           + "Proxy-Authenticate: Basic realm=\"iskra\"\r\nConnection: close\r\n\r\n")
        }
        guard let (host, port) = splitAuthority(String(parts[1])) else {
            return .refuse("HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n")
        }
        return .connect(host: host, port: port)
    }

    /// `matrix.org:443` → (`matrix.org`, 443); `[::1]:8448` → (`::1`, 8448). Nothing without a port.
    static func splitAuthority(_ authority: String) -> (String, UInt16)? {
        guard let colon = authority.lastIndex(of: ":"),
              let port = UInt16(authority[authority.index(after: colon)...]), port != 0 else { return nil }
        var host = String(authority[..<colon])
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        guard !host.isEmpty else { return nil }
        return (host, port)
    }

    /// A comparison whose time does not say how much of the secret was right.
    private static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

/// A `CONNECT` carried by an ordinary TCP connection, opened right here — no bridge, no nostr.
///
/// For tests: it proves that the SDK, built with a proxy, really sends *everything* through it —
/// sign-in, sliding sync, media, the notification extension's client — before any bridge is
/// involved. `ports` is the evidence: the local port of every connection it made, which the
/// listener on the far side can hold its own connections against.
final class DirectPipe: ConnectUpstream {
    private let made = Mutex<[UInt16]>([])

    var ports: [UInt16] { made.withLock { $0 } }

    func carry(_ socket: LocalSocket, host: String, port: UInt16, leftover: Data) async {
        guard let remote = LocalSocket(host: host, port: port), await remote.start() else {
            return socket.reset()
        }
        if let local = remote.localPort { made.withLock { $0.append(local) } }
        if !leftover.isEmpty, (try? await remote.send(leftover)) == nil {
            remote.reset()
            return socket.reset()
        }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await Self.copy(from: socket, to: remote) }
            group.addTask { await Self.copy(from: remote, to: socket) }
        }
        socket.close()
        remote.close()
    }

    /// One direction, until it ends. A failure ends both: a pipe half broken is a pipe broken.
    private static func copy(from source: LocalSocket, to sink: LocalSocket) async {
        while true {
            do {
                guard let data = try await source.receive() else {
                    await sink.finishWriting()
                    return
                }
                if !data.isEmpty { try await sink.send(data) }
            } catch {
                source.reset()
                sink.reset()
                return
            }
        }
    }
}
