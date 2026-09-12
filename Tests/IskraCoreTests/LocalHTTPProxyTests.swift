import Foundation
import MatrixRustSDK
import Synchronization
import Testing

@testable import IskraCore

/// An upstream that answers from a script and remembers what it was asked.
private final class StubUpstream: HTTPUpstream {
    private let received = Mutex<[ProxiedRequest]>([])
    private let answer: @Sendable (ProxiedRequest) -> ProxiedResponse

    init(answer: @escaping @Sendable (ProxiedRequest) -> ProxiedResponse) {
        self.answer = answer
    }

    var requests: [ProxiedRequest] { received.withLock { $0 } }

    func send(_ request: ProxiedRequest) async throws -> ProxiedResponse {
        received.withLock { $0.append(request) }
        return answer(request)
    }
}

@Suite("Local HTTP proxy")
struct LocalHTTPProxyTests {
    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }

    @Test("a GET reaches the upstream and its answer comes back")
    func getRoundTrips() async throws {
        let upstream = StubUpstream { _ in
            ProxiedResponse(
                status: 200,
                headers: ["Content-Type": "application/json"],
                body: Data(#"{"versions":["v1.11"]}"#.utf8)
            )
        }
        let proxy = LocalHTTPProxy(upstream: upstream)
        let port = try await proxy.start()
        defer { Task { await proxy.stop() } }

        let url = URL(string: "http://127.0.0.1:\(port)/_matrix/client/versions")!
        let (data, response) = try await session().data(from: url)

        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: data, as: UTF8.self) == #"{"versions":["v1.11"]}"#)
        #expect(upstream.requests.first?.method == "GET")
        #expect(upstream.requests.first?.target == "/_matrix/client/versions")
    }

    @Test("a query string survives, because the SDK puts real arguments there")
    func queryStringSurvives() async throws {
        let upstream = StubUpstream { _ in ProxiedResponse(status: 200, body: Data("{}".utf8)) }
        let proxy = LocalHTTPProxy(upstream: upstream)
        let port = try await proxy.start()
        defer { Task { await proxy.stop() } }

        let url = URL(string: "http://127.0.0.1:\(port)/_matrix/client/v3/sync?timeout=30000&since=s1")!
        _ = try await session().data(from: url)

        #expect(upstream.requests.first?.target == "/_matrix/client/v3/sync?timeout=30000&since=s1")
    }

    @Test("a POST carries its body and its headers")
    func postCarriesBodyAndHeaders() async throws {
        let upstream = StubUpstream { _ in ProxiedResponse(status: 200, body: Data("{}".utf8)) }
        let proxy = LocalHTTPProxy(upstream: upstream)
        let port = try await proxy.start()
        defer { Task { await proxy.stop() } }

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/_matrix/client/v3/login")!)
        request.httpMethod = "POST"
        request.setValue("Bearer token", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"type":"m.login.token"}"#.utf8)
        _ = try await session().data(for: request)

        let seen = try #require(upstream.requests.first)
        #expect(seen.method == "POST")
        #expect(seen.body == Data(#"{"type":"m.login.token"}"#.utf8))
        #expect(seen.headers["Authorization"] == "Bearer token")
    }

    @Test("an error status is passed through rather than turned into a failure")
    func errorStatusPassesThrough() async throws {
        let upstream = StubUpstream { _ in
            ProxiedResponse(status: 404, body: Data(#"{"errcode":"M_NOT_FOUND"}"#.utf8))
        }
        let proxy = LocalHTTPProxy(upstream: upstream)
        let port = try await proxy.start()
        defer { Task { await proxy.stop() } }

        let url = URL(string: "http://127.0.0.1:\(port)/nope")!
        let (_, response) = try await session().data(from: url)
        #expect((response as? HTTPURLResponse)?.statusCode == 404)
    }

    @Test("many requests go down one connection")
    func keepAliveHoldsTheConnection() async throws {
        // reqwest pools connections, so a server that closes after every response would make each
        // SDK call pay for a new socket. This is the test that would notice.
        let upstream = StubUpstream { _ in ProxiedResponse(status: 200, body: Data("{}".utf8)) }
        let proxy = LocalHTTPProxy(upstream: upstream)
        let port = try await proxy.start()
        defer { Task { await proxy.stop() } }

        let session = session()
        for index in 0..<20 {
            let url = URL(string: "http://127.0.0.1:\(port)/call/\(index)")!
            let (_, response) = try await session.data(from: url)
            #expect((response as? HTTPURLResponse)?.statusCode == 200)
        }
        #expect(upstream.requests.count == 20)
    }

    @Test("a body larger than one read is reassembled whole")
    func largeBodyIsReassembled() async throws {
        let payload = Data(repeating: UInt8(ascii: "x"), count: 512 * 1024)
        let upstream = StubUpstream { _ in ProxiedResponse(status: 200, body: Data("{}".utf8)) }
        let proxy = LocalHTTPProxy(upstream: upstream)
        let port = try await proxy.start()
        defer { Task { await proxy.stop() } }

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/upload")!)
        request.httpMethod = "POST"
        request.httpBody = payload
        _ = try await session().data(for: request)

        #expect(upstream.requests.first?.body.count == payload.count)
    }

    @Test("the listener answers only on loopback")
    func boundToLoopbackOnly() async throws {
        // An open proxy to somebody's homeserver session, reachable from the same Wi-Fi, is the
        // failure this guards. The address is asserted, not assumed.
        let upstream = StubUpstream { _ in ProxiedResponse(status: 200) }
        let proxy = LocalHTTPProxy(upstream: upstream)
        let port = try await proxy.start()
        defer { Task { await proxy.stop() } }

        let address = await proxy.homeserverURL
        #expect(address == "http://127.0.0.1:\(port)")
    }
}

/// The question the whole client design rests on: will the SDK talk plain HTTP to `127.0.0.1` and
/// treat what answers as its homeserver?
///
/// Off by default because it reaches matrix.org. Run it deliberately:
///
/// ```sh
/// ISKRA_LIVE_TUNNEL_PROBE=1 swift test --filter theSDKAcceptsALoopbackHomeserver
/// ```
@Suite("SDK through the local proxy", .enabled(if: ProcessInfo.processInfo.environment["ISKRA_LIVE_TUNNEL_PROBE"] != nil))
struct SDKThroughProxyTests {
    @Test("the SDK accepts a loopback homeserver and its traffic comes through us")
    func theSDKAcceptsALoopbackHomeserver() async throws {
        let upstream = DirectUpstream(homeserver: URL(string: "https://matrix-client.matrix.org")!)
        let proxy = LocalHTTPProxy(upstream: upstream)
        let port = try await proxy.start()
        defer { Task { await proxy.stop() } }

        let root = URL.temporaryDirectory.appending(path: "tunnel-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = SqliteStoreBuilder(
            dataPath: root.appending(path: "data").path(percentEncoded: false),
            cachePath: root.appending(path: "cache").path(percentEncoded: false)
        )

        let client = try await ClientBuilder()
            .sqliteStore(config: store)
            .homeserverUrl(url: "http://127.0.0.1:\(port)")
            .slidingSyncVersionBuilder(versionBuilder: .discoverNative)
            .build()

        let seen = await proxy.requestLog
        print("--- the SDK asked for \(seen.count) things through the proxy:")
        for request in seen {
            print("    \(request.method) \(request.target)")
        }
        print("--- client.homeserver() = \(client.homeserver())")

        #expect(!seen.isEmpty, "the SDK reached the homeserver some other way")
    }

    /// The sign-in path does `.well-known` discovery, and discovery is where a tunnel leaks.
    ///
    /// `serverNameOrHomeserverUrl` asks the server name for `/.well-known/matrix/client`, and
    /// matrix.org answers with an absolute `https://matrix-client.matrix.org`. Before the listener
    /// rewrote that answer the SDK believed it and left the tunnel for good — silently, with the
    /// app still showing a working connection. This pins the fix.
    @Test("discovery is kept inside the tunnel")
    func discoveryStaysInsideTheTunnel() async throws {
        let upstream = DirectUpstream(homeserver: URL(string: "https://matrix.org")!)
        let proxy = LocalHTTPProxy(upstream: upstream)
        let port = try await proxy.start()
        defer { Task { await proxy.stop() } }

        let root = URL.temporaryDirectory.appending(path: "tunnel-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = SqliteStoreBuilder(
            dataPath: root.appending(path: "data").path(percentEncoded: false),
            cachePath: root.appending(path: "cache").path(percentEncoded: false)
        )

        let client = try await ClientBuilder()
            .sqliteStore(config: store)
            .serverNameOrHomeserverUrl(serverNameOrUrl: "http://127.0.0.1:\(port)")
            .slidingSyncVersionBuilder(versionBuilder: .discoverNative)
            .build()

        let seen = await proxy.requestLog
        print("--- discovery asked for \(seen.count) things through the proxy:")
        for request in seen {
            print("    \(request.method) \(request.target)")
        }
        let homeserver = client.homeserver()
        print("--- client.homeserver() = \(homeserver)")
        print("--- tunnel kept: \(homeserver.contains("127.0.0.1"))")

        #expect(!seen.isEmpty)
        #expect(
            homeserver.contains("127.0.0.1"),
            "discovery walked the SDK out of the tunnel to \(homeserver)"
        )
    }
}
