import Foundation
import MatrixRustSDK
import Testing
@testable import IskraCore

/// The one test that needs a bridge, a relay and the internet — so it is off unless asked for.
///
/// Everything else about the tunnel is pinned without a network: the encryption against the NIP-44
/// vector file, the envelope against the spelling serde expects, the event against its own hash.
/// What none of that can prove is that the two implementations meet. This does, against a bridge
/// running on this machine:
///
/// ```sh
/// cd Bridge && ./run-local.sh            # prints `bridge is listening pubkey=…`
/// ISKRA_BRIDGE_PUBKEY=<that key> swift test --filter LiveBridgeTests
/// ```
///
/// Same bargain as the Rust side's `#[ignore]`d stress suite: `swift test` stays offline and fast,
/// and the live check is one command away when it is wanted.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["ISKRA_BRIDGE_PUBKEY"] != nil))
struct LiveBridgeTests {
    static var bridgeKey: Data {
        let text = ProcessInfo.processInfo.environment["ISKRA_BRIDGE_PUBKEY"] ?? ""
        guard case .success(let key) = BridgeAddress.publicKey(from: text) else {
            fatalError("ISKRA_BRIDGE_PUBKEY is not a nostr public key")
        }
        return key
    }

    static var relays: [URL] {
        let written = ProcessInfo.processInfo.environment["ISKRA_BRIDGE_RELAYS"] ?? ""
        let parsed = TunnelSettings.parseRelays(written)
        return parsed.isEmpty ? TunnelSettings.defaultRelays.compactMap(URL.init(string:)) : parsed
    }

    /// A tunnel of its own per test, with a key of its own: the Keychain is not open to an
    /// unsigned test binary, and a shared key would make the rate limit a shared budget.
    private func tunnel(limit: Duration = .seconds(30)) throws -> NostrTunnelUpstream {
        try NostrTunnelUpstream(bridgeKey: Self.bridgeKey,
                                relays: Self.relays,
                                keys: try TunnelIdentity(secrets: InMemorySecrets()).keypair(),
                                homeserver: URL(string: "https://matrix-client.matrix.org")!,
                                limit: limit)
    }

    /// The whole journey: request → NIP-44 → relay → bridge → matrix.org → back.
    @Test func aRequestGoesOutThroughNostrAndComesBackWithMatrixInIt() async throws {
        let bridge = try tunnel()

        await bridge.start()
        defer { Task { await bridge.stop() } }

        let response = try await bridge.send(ProxiedRequest(method: "GET",
                                                            target: "/_matrix/client/versions"))
        #expect(response.status == 200)
        #expect(String(decoding: response.body, as: UTF8.self).contains("\"versions\""))
    }

    /// Two at once, which is where a transport with one reader per request comes apart: each
    /// answer has to reach the one caller waiting for it and nobody else.
    @Test func severalRequestsInFlightEachGetTheirOwnAnswer() async throws {
        let bridge = try tunnel()

        await bridge.start()
        defer { Task { await bridge.stop() } }

        let paths = ["/_matrix/client/versions",
                     "/_matrix/client/v3/login",
                     "/_matrix/client/versions"]

        try await withThrowingTaskGroup(of: (String, Int).self) { group in
            for path in paths {
                group.addTask {
                    let response = try await bridge.send(ProxiedRequest(method: "GET", target: path))
                    return (path, response.status)
                }
            }
            for try await (path, status) in group {
                #expect(status == 200, "\(path) answered \(status)")
            }
        }
    }

    /// And the diagnosis the settings screen shows, against the same bridge.
    @Test func theCheckSaysItIsReachable() async throws {
        let outcome = await BridgeCheck.run(bridgeKey: Self.bridgeKey,
                                            relays: Self.relays,
                                            homeserver: URL(string: "https://matrix-client.matrix.org")!,
                                            identity: TunnelIdentity(secrets: InMemorySecrets()))
        guard case .reachable(let milliseconds) = outcome else {
            Issue.record("the bridge was not reachable: \(outcome)")
            return
        }
        #expect(milliseconds > 0)
    }

    /// An answer far too big for one event, which is where the tunnel used to stop.
    ///
    /// `publicRooms` is the largest thing matrix.org hands a stranger: about 48 KB however high the
    /// limit is asked for, which is two chunks. Two is enough to prove the pair — the bridge's
    /// chunker against this side's reassembler, across two languages and a relay that reorders —
    /// and the sizes where that gets interesting (4 MB, 171 chunks) are the Rust stress suite's
    /// job, against a homeserver that will answer with as much as it is asked for.
    @Test func ananswerTooBigForOneEventComesBackWhole() async throws {
        let bridge = try tunnel(limit: .seconds(60))
        await bridge.start()
        defer { Task { await bridge.stop() } }

        let response = try await bridge.send(ProxiedRequest(
            method: "GET", target: "/_matrix/client/v3/publicRooms?limit=200"))

        #expect(response.status == 200)
        #expect(response.body.count > TunnelChunker.defaultMaxBodyChunk,
                "\(response.body.count) bytes is one chunk; this test proves nothing at that size")
        // Whole, not merely long: the JSON has to parse, which it will not if two chunks changed
        // places or one went missing in the middle.
        let parsed = try JSONSerialization.jsonObject(with: response.body) as? [String: Any]
        #expect(parsed?["chunk"] != nil)
    }

    /// And the other direction: a request body the client cannot fit in one event.
    ///
    /// This is what sending a photo looks like from here. matrix.org answers a login it cannot make
    /// sense of with a 400, and that is the whole point — a 400 means the bridge reassembled the
    /// chunks and a homeserver read them. Silence would mean it did not.
    @Test func arequestTooBigForOneEventReachesTheHomeserver() async throws {
        let bridge = try tunnel(limit: .seconds(60))
        await bridge.start()
        defer { Task { await bridge.stop() } }

        // 100 KB of JSON: five chunks, and valid JSON so that nothing between here and there can
        // blame the shape of it.
        let padding = String(repeating: "a", count: 100_000)
        let body = Data(#"{"type":"m.login.password","identifier":"\#(padding)"}"#.utf8)

        let response = try await bridge.send(ProxiedRequest(
            method: "POST",
            target: "/_matrix/client/v3/login",
            headers: ["content-type": "application/json"],
            body: body))

        // 400 or 401 — a homeserver's opinion of the login, which it can only have if it read the
        // body. **Not** 403: that is the bridge's own refusal, and accepting it here would make
        // this a test that passes when the chunks never left the machine.
        #expect(response.status == 400 || response.status == 401,
                "matrix.org said \(response.status)")
    }

    /// The thing all of it is for: the **Matrix SDK itself** talking through the tunnel.
    ///
    /// Everything above proves the transport carries a request. This proves the SDK will use it —
    /// built against the loopback listener exactly as `AuthenticationService.route` builds it, and
    /// then asked the question the "Continue" button asks. What comes back is matrix.org's own
    /// answer about how it lets people in, and it came back through nostr.
    @Test func theSDKSignsInThroughTheTunnel() async throws {
        let root = FileManager.default.temporaryDirectory.appending(component: "iskra-tunnel-\(UUID().uuidString)")
        let data = root.appending(component: "data")
        let cache = root.appending(component: "cache")
        let search = root.appending(component: "search")
        for url in [data, cache, search] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }

        let homeserver = URL(string: "https://matrix.org")!
        let bridge = try NostrTunnelUpstream(bridgeKey: Self.bridgeKey,
                                             relays: Self.relays,
                                             keys: try TunnelIdentity(secrets: InMemorySecrets()).keypair(),
                                             homeserver: homeserver)
        await bridge.start()
        defer { Task { await bridge.stop() } }

        // The same wiring the app uses, including the hand-off when `.well-known` says the API
        // lives somewhere other than the name that was typed.
        let proxy = LocalHTTPProxy(upstream: bridge)
        let port = try await proxy.start()
        defer { Task { await proxy.stop() } }

        let store = SqliteStoreBuilder(dataPath: data.path(percentEncoded: false),
                                       cachePath: cache.path(percentEncoded: false))
            .passphrase(passphrase: UUID().uuidString)

        let client = try await ClientBuilder()
            .sqliteStore(config: store)
            .withSearchIndexStore(path: search.path(percentEncoded: false), password: UUID().uuidString)
            .homeserverUrl(url: "http://127.0.0.1:\(port)")
            .slidingSyncVersionBuilder(versionBuilder: .native)
            .build()

        let details = await client.homeserverLoginDetails()
        #expect(details.supportsOauthLogin() || details.supportsPasswordLogin())

        // And the listener really is what the SDK went through, rather than the SDK having found
        // its own way to matrix.org.
        let seen = await proxy.requestLog
        #expect(seen.contains { $0.target.hasPrefix("/_matrix/client/versions") })
    }

    /// A key that is not the bridge's gets silence, not somebody else's traffic.
    @Test func thewrongKeyIsSilence() async throws {
        let stranger = try NostrKeypair.generate()
        let outcome = await BridgeCheck.run(bridgeKey: stranger.publicKey,
                                            relays: Self.relays,
                                            homeserver: URL(string: "https://matrix-client.matrix.org")!,
                                            identity: TunnelIdentity(secrets: InMemorySecrets()),
                                            limit: .seconds(10))
        #expect(outcome == .silent)
    }
}
