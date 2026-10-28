import Foundation
import MatrixRustSDK
import Testing
@testable import IskraCore

/// The one test that needs a bridge, a relay and the internet — so it is off unless asked for.
///
/// Everything else about the bridge is pinned without a network: the encryption against the NIP-44
/// vector file, the frames against the text serde writes, the window against the questions
/// `stream.rs` is asked, the SDK against a stand-in bridge in process. What none of that can prove
/// is that the two implementations meet. This does, against a bridge running on this machine:
///
/// ```sh
/// cd Bridge && ./run-local.sh            # prints `bridge is listening pubkey=…`
/// ISKRA_BRIDGE_PUBKEY=<that key> swift test --filter LiveBridgeTests
/// ```
///
/// The bridge has to let this device through to matrix.org: `ALLOWED_UPSTREAMS` covering
/// `https://matrix.org` and `https://matrix-client.matrix.org`, or `*`.
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

    static let api = URL(string: "https://matrix-client.matrix.org")!

    /// A bridge of its own per test, with a key of its own: the Keychain is not open to an unsigned
    /// test binary, and a shared key would make the bridge's per-key ceilings a shared budget.
    private struct Rig {
        let streams: NostrStreamTunnel
        let connect: LocalConnectProxy

        func stop() async {
            await connect.stop()
            await streams.stop()
        }

        func get(_ path: String, timeout: Double = 30) async throws -> (Int, Data) {
            var request = URLRequest(url: URL(string: path, relativeTo: LiveBridgeTests.api)!.absoluteURL)
            request.timeoutInterval = timeout
            let (data, response) = try await connect.urlSession().data(for: request)
            return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
        }
    }

    private func rig() async throws -> Rig {
        let streams = try NostrStreamTunnel(bridgeKey: Self.bridgeKey, relays: Self.relays,
                                            keys: try TunnelIdentity(secrets: InMemorySecrets()).keypair())
        await streams.start()
        let connect = LocalConnectProxy(upstream: streams)
        try await connect.start()
        return Rig(streams: streams, connect: connect)
    }

    /// The whole journey: TLS → stream frames → NIP-44 → relay → bridge → matrix.org → back.
    @Test func aConnectionGoesOutThroughNostrAndComesBackWithMatrixInIt() async throws {
        let rig = try await rig()
        defer { Task { await rig.stop() } }

        let (status, body) = try await rig.get("/_matrix/client/versions")
        #expect(status == 200)
        #expect(String(bytes: body, encoding: .utf8)?.contains("\"versions\"") == true)
    }

    /// Several at once, which is where a transport with one reader per stream comes apart: each
    /// stream's frames have to reach that stream and no other.
    @Test func severalRequestsInFlightEachGetTheirOwnAnswer() async throws {
        let rig = try await rig()
        defer { Task { await rig.stop() } }

        let paths = ["/_matrix/client/versions", "/_matrix/client/v3/login", "/_matrix/client/versions"]
        try await withThrowingTaskGroup(of: (String, Int).self) { group in
            for path in paths {
                group.addTask { (path, try await rig.get(path).0) }
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
                                            homeserver: Self.api,
                                            identity: TunnelIdentity(secrets: InMemorySecrets()))
        guard case .reachable(let milliseconds) = outcome else {
            Issue.record("the bridge was not reachable: \(outcome)")
            return
        }
        #expect(milliseconds > 0)
    }

    /// An answer far bigger than one event: several segments, a window, acknowledgements, across
    /// two languages and relays that reorder. `publicRooms` is the largest thing matrix.org hands a
    /// stranger, about 48 KB.
    @Test func ananswerTooBigForOneEventComesBackWhole() async throws {
        let rig = try await rig()
        defer { Task { await rig.stop() } }

        let (status, body) = try await rig.get("/_matrix/client/v3/publicRooms?limit=200", timeout: 60)
        #expect(status == 200)
        #expect(body.count > StreamFrame.defaultSegment,
                "\(body.count) bytes is one segment; this test proves nothing at that size")
        // Whole, not merely long: the JSON has to parse, which it will not if two segments changed
        // places or one went missing in the middle.
        let parsed = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        #expect(parsed?["chunk"] != nil)
    }

    /// The thing all of it is for: the **Matrix SDK itself**, built the way `AuthenticationService`
    /// builds it — the real homeserver's address and the bridge as its proxy — asked the question
    /// the "Continue" button asks.
    @Test func theSDKFindsTheServerThroughTheBridge() async throws {
        let root = FileManager.default.temporaryDirectory.appending(component: "iskra-bridge-\(UUID().uuidString)")
        let data = root.appending(component: "data")
        let cache = root.appending(component: "cache")
        let search = root.appending(component: "search")
        for url in [data, cache, search] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }

        let rig = try await rig()
        defer { Task { await rig.stop() } }
        let proxy = try #require(await rig.connect.proxyURL)

        let store = SqliteStoreBuilder(dataPath: data.path(percentEncoded: false),
                                       cachePath: cache.path(percentEncoded: false))
            .passphrase(passphrase: UUID().uuidString)
        let client = try await ClientBuilder()
            .sqliteStore(config: store)
            .withSearchIndexStore(path: search.path(percentEncoded: false), password: UUID().uuidString)
            .serverNameOrHomeserverUrl(serverNameOrUrl: "matrix.org")
            .proxy(url: proxy)
            .slidingSyncVersionBuilder(versionBuilder: .discoverNative)
            .build()

        let details = await client.homeserverLoginDetails()
        #expect(details.supportsOauthLogin() || details.supportsPasswordLogin())
        // And the listener really is what the SDK went through.
        #expect(await rig.connect.carried > 0)
    }

    /// Back from the background with every relay connection gone, the bridge answers again at once.
    ///
    /// What a pocket does to a phone: the sockets die with nobody told, and the reconnect loops are
    /// asleep in a backoff that can have climbed to thirty seconds. `wake()` is what the session
    /// calls on the way back to the front, and after it the first request has to go through within
    /// seconds.
    @Test func afterEveryConnectionIsLostWakeBringsTheBridgeBack() async throws {
        let rig = try await rig()
        defer { Task { await rig.stop() } }

        #expect(try await rig.get("/_matrix/client/versions").0 == 200)

        await rig.streams.severConnections()
        // Long enough for the reconnect loops to have gone to sleep in their backoff.
        try await Task.sleep(for: .milliseconds(500))
        await rig.streams.wake()

        let started = ContinuousClock.now
        let again = try await rig.get("/_matrix/client/versions")
        let took = started.duration(to: .now)
        #expect(again.0 == 200)
        #expect(took < .seconds(8), "the first request after waking took \(took)")
    }

    /// A key that is not the bridge's gets silence, not somebody else's traffic.
    @Test func thewrongKeyIsSilence() async throws {
        let stranger = try NostrKeypair.generate()
        let outcome = await BridgeCheck.run(bridgeKey: stranger.publicKey,
                                            relays: Self.relays,
                                            homeserver: Self.api,
                                            identity: TunnelIdentity(secrets: InMemorySecrets()),
                                            limit: .seconds(10))
        #expect(outcome == .silent)
    }
}
