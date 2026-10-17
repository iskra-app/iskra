import Foundation
import Network
import Security
import Synchronization
@testable import IskraCore

/// A certificate for `127.0.0.1` that nothing on the machine trusts, made fresh for each run — so
/// there is no fixture to expire — and the identity to serve it with.
///
/// The homeserver of the blind-route tests stands behind it, and the SDK is told to trust it
/// (`ClientBuilder.addRootCertificates`). That is what puts real TLS between the SDK and the
/// homeserver, and so what makes the SDK `CONNECT` through its proxy the way it would to matrix.org.
enum TestTLS {
    struct Material {
        let identity: TLSIdentity
        /// The certificate, DER, for `addRootCertificates`.
        let certificate: Data
    }

    static func make() throws -> Material {
        let directory = FileManager.default.temporaryDirectory.appending(component: "iskra-tls-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func path(_ name: String) -> String { directory.appending(component: name).path(percentEncoded: false) }

        try openssl(["req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1", "-nodes",
                     "-keyout", path("key.pem"), "-out", path("cert.pem"), "-days", "30",
                     "-subj", "/CN=127.0.0.1",
                     "-addext", "subjectAltName=IP:127.0.0.1,DNS:localhost,DNS:homeserver.test",
                     "-addext", "extendedKeyUsage=serverAuth",
                     "-addext", "basicConstraints=critical,CA:FALSE"])
        try openssl(["x509", "-in", path("cert.pem"), "-outform", "der", "-out", path("cert.der")])
        try openssl(["pkcs12", "-export", "-inkey", path("key.pem"), "-in", path("cert.pem"),
                     "-out", path("identity.p12"), "-passout", "pass:iskra",
                     "-certpbe", "PBE-SHA1-3DES", "-keypbe", "PBE-SHA1-3DES", "-macalg", "sha1"])

        let p12 = try Data(contentsOf: URL(filePath: path("identity.p12")))
        var items: CFArray?
        let options: [String: Any] = [kSecImportExportPassphrase as String: "iskra",
                                      kSecImportToMemoryOnly as String: true]
        let status = SecPKCS12Import(p12 as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess,
              let first = (items as? [[String: Any]])?.first,
              let found = first[kSecImportItemIdentity as String]
        else { throw Failure.importFailed(status) }
        // swiftlint:disable:next force_cast
        let identity = found as! SecIdentity
        guard let secIdentity = sec_identity_create(identity) else { throw Failure.importFailed(status) }
        return Material(identity: TLSIdentity(identity: secIdentity),
                        certificate: try Data(contentsOf: URL(filePath: path("cert.der"))))
    }

    enum Failure: Error {
        case openssl(Int32)
        case importFailed(OSStatus)
    }

    private static func openssl(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/env")
        process.arguments = ["openssl"] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Failure.openssl(process.terminationStatus) }
    }
}

/// A TCP server on loopback that writes back whatever it is sent, and closes its half when the
/// other side closes theirs.
final class EchoServer: Sendable {
    private let listener: LoopbackListener

    init() {
        listener = LoopbackListener { connection in
            Task.detached {
                let socket = LocalSocket(connection)
                guard await socket.start() else { return }
                while let data = try? await socket.receive() {
                    guard (try? await socket.send(data)) != nil else { return socket.reset() }
                }
                await socket.finishWriting()
            }
        }
    }

    func start() async throws -> UInt16 { try await listener.start() }
    func stop() async { await listener.stop() }
}

/// The bridge's half of protocol v2, in process, with no relays: the same `StreamPump` the app
/// runs, in the `.bridge` role, connecting to the host in each `open` itself.
///
/// What it adds is the relays' manners. Every frame is serialised to the wire and read back, so the
/// JSON is exercised; and delivery is out of order, by a random few milliseconds, with some frames
/// arriving twice — what three relays racing each other do to a stream.
actor TestStreamBridge {
    /// Frames for one stream that arrived while its connection was still being made.
    private var pending: [String: [StreamFrame]] = [:]
    private var pumps: [String: StreamPump] = [:]
    private var opening: Set<String> = []
    private var toClient: StreamLink = { _ in }
    /// Frames from the client this bridge pretends it never heard. For the gap test.
    private var drop: @Sendable (StreamFrame) -> Bool = { _ in false }
    private(set) var opened = 0
    private var refusal: String?

    func connect(toClient: @escaping StreamLink) {
        self.toClient = Self.unruly(toClient)
    }

    func dropping(_ rule: @escaping @Sendable (StreamFrame) -> Bool) {
        drop = rule
    }

    /// Answer every `open` with an `rst` and this reason, the way a bridge does that will not take
    /// the device to that host.
    func refusing(with reason: String) {
        refusal = reason
    }

    /// The client's link: where `StreamCarrier` sends its frames.
    nonisolated var link: StreamLink {
        Self.unruly { [weak self] frame in await self?.receive(frame) }
    }

    private func receive(_ frame: StreamFrame) async {
        guard !drop(frame) else { return }
        if let pump = pumps[frame.sid] { return await pump.deliver(frame) }
        if frame.op == .open, let refusal {
            try? await toClient(.rst(frame.sid, reason: refusal))
            return
        }
        if frame.op == .open, !opening.contains(frame.sid) {
            opening.insert(frame.sid)
            pending[frame.sid, default: []] = pending[frame.sid] ?? []
            Task { await self.open(frame) }
        } else {
            // The connection is still being made, or a frame overtook its `open`: held until then.
            pending[frame.sid, default: []].append(frame)
        }
    }

    private func open(_ open: StreamFrame) async {
        guard let host = open.host, let port = open.port,
              let socket = LocalSocket(host: host, port: port), await socket.start() else {
            pending[open.sid] = nil
            try? await toClient(.rst(open.sid, reason: StreamReason.unreachable))
            return
        }
        let pump = StreamPump(sid: open.sid, role: .bridge, socket: socket, link: toClient)
        pumps[open.sid] = pump
        opened += 1
        let early = pending.removeValue(forKey: open.sid) ?? []
        try? await toClient(.opened(open.sid))
        await pump.deliver(open)
        for frame in early { await pump.deliver(frame) }
        Task {
            _ = await pump.run()
            self.forget(open.sid)
        }
    }

    private func forget(_ sid: String) {
        pumps[sid] = nil
    }

    /// A link that behaves like relays: through the wire format, late by up to a few milliseconds,
    /// so out of order, and now and then twice.
    private static func unruly(_ deliver: @escaping StreamLink) -> StreamLink {
        { frame in
            let copies = Int.random(in: 0..<8) == 0 ? 2 : 1
            for _ in 0..<copies {
                Task {
                    try? await Task.sleep(for: .microseconds(Int.random(in: 0...3_000)))
                    guard let decoded = try? JSONDecoder().decode(StreamFrame.self, from: frame.wire).validated() else {
                        return
                    }
                    try? await deliver(decoded)
                }
            }
        }
    }
}

/// The client half for the tests: `StreamCarrier` with a `TestStreamBridge` as its relays.
final class TestStreamTunnel: ConnectUpstream {
    let bridge: TestStreamBridge
    let carrier: StreamCarrier
    /// What the client side heard from the bridge, as `NostrStreamTunnel` keeps it.
    let heard: Heard
    private let outcomes = Mutex<[StreamOutcome]>([])

    init() async {
        let bridge = TestStreamBridge()
        let carrier = StreamCarrier(link: bridge.link)
        let heard = Heard()
        self.bridge = bridge
        self.carrier = carrier
        self.heard = heard
        await bridge.connect { frame in
            heard.frame(frame)
            await carrier.deliver(frame)
        }
    }

    var ended: [StreamOutcome] { outcomes.withLock { $0 } }

    func carry(_ socket: LocalSocket, host: String, port: UInt16, leftover: Data) async {
        let outcome = await carrier.carry(socket, host: host, port: port, leftover: leftover)
        outcomes.withLock { $0.append(outcome) }
    }
}

/// A raw client of `LocalConnectProxy`: connects, sends a head, and reads what comes back.
enum ConnectClient {
    static func connect(port: UInt16) async throws -> LocalSocket {
        guard let socket = LocalSocket(host: "127.0.0.1", port: port), await socket.start() else {
            throw LocalHTTPProxy.ProxyError.notStarted
        }
        return socket
    }

    /// The proxy's answer to `head`: its status line.
    static func statusLine(after head: String, on socket: LocalSocket) async throws -> String {
        try await socket.send(Data(head.utf8))
        var answer = Data()
        while answer.range(of: Data("\r\n\r\n".utf8)) == nil {
            guard let chunk = try await socket.receive() else { break }
            answer.append(chunk)
        }
        return String(decoding: answer, as: UTF8.self).components(separatedBy: "\r\n").first ?? ""
    }

    /// `CONNECT` with the secret out of `proxyURL`.
    static func head(to target: String, proxyURL: String?) -> String {
        let secret = proxyURL.flatMap { URL(string: $0)?.password() } ?? ""
        let token = Data("iskra:\(secret)".utf8).base64EncodedString()
        return "CONNECT \(target) HTTP/1.1\r\nHost: \(target)\r\nProxy-Authorization: Basic \(token)\r\n\r\n"
    }

    /// Everything until the other side closes, or `count` bytes.
    static func read(_ count: Int, from socket: LocalSocket) async throws -> Data {
        var received = Data()
        while received.count < count, let chunk = try await socket.receive() {
            received.append(chunk)
        }
        return received
    }
}

/// A pipe that knows one name nobody else does: `homeserver.test` is this machine.
///
/// For `URLSession`, which goes straight to a loopback address whatever proxy it is given — so a
/// test that asked it for `127.0.0.1` would pass without the proxy ever being used. Given a name it
/// cannot resolve, it has to ask the proxy, and only the proxy knows where that is.
final class NamedPipe: ConnectUpstream {
    static let name = "homeserver.test"
    private let pipe = DirectPipe()

    func carry(_ socket: LocalSocket, host: String, port: UInt16, leftover: Data) async {
        await pipe.carry(socket, host: host == Self.name ? "127.0.0.1" : host, port: port, leftover: leftover)
    }
}
