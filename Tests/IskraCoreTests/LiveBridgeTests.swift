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

    /// The whole journey: request → NIP-44 → relay → bridge → matrix.org → back.
    @Test func aRequestGoesOutThroughNostrAndComesBackWithMatrixInIt() async throws {
        let identity = TunnelIdentity(secrets: InMemorySecrets())
        let bridge = try NostrTunnelUpstream(
            bridgeKey: Self.bridgeKey,
            relays: Self.relays,
            keys: try identity.keypair(),
            homeserver: URL(string: "https://matrix-client.matrix.org")!,
            limit: .seconds(30))

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
        let identity = TunnelIdentity(secrets: InMemorySecrets())
        let bridge = try NostrTunnelUpstream(
            bridgeKey: Self.bridgeKey,
            relays: Self.relays,
            keys: try identity.keypair(),
            homeserver: URL(string: "https://matrix-client.matrix.org")!,
            limit: .seconds(30))

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
