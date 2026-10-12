import Foundation
import MatrixRustSDK

/// Signing in to the demo server, which lives in this process — see `MockHomeserver`.
///
/// The demo is a session like any other from `UserSession` upwards, and deliberately nothing like
/// one underneath, because the one thing it must never do is touch the real account:
///
/// - **Nothing goes in the Keychain.** No tokens are saved, and the store's passphrase and search
///   key are random, made up for this one run. The account somebody is really signed in to stays
///   exactly where it was, and turning the demo off finds it there.
/// - **The store is thrown away every time.** It lives under its own session ID, it is emptied
///   before each demo begins, and `sweepOrphanedStores` clears it at the next launch because the
///   Keychain has never heard of it. The demo server's memory is thrown away at the same moments,
///   so the two cannot disagree about what happened.
/// - **No session delegate.** It exists to write refreshed tokens into the Keychain, and the demo
///   has no tokens worth writing and no business writing anything there.
public enum DemoBackend {
    /// The session ID the demo's store is kept under. Not a UUID, so it is recognisable on disk.
    static let sessionID = "demo"

    /// The user the demo signs in as.
    static let username = "sasha"

    /// Builds a client against the demo server, with a fresh store in the three directories given,
    /// and signs it in. The test suite calls this with temporary directories; the app, with the
    /// same places a real session's store would go.
    static func makeClient(data: URL, cache: URL, search: URL) async throws -> Client {
        for url in [data, cache, search] {
            try? FileManager.default.removeItem(at: url)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }

        let homeserver = try await DemoListener.shared.homeserverURL()

        let store = SqliteStoreBuilder(dataPath: data.path(percentEncoded: false),
                                       cachePath: cache.path(percentEncoded: false))
            .passphrase(passphrase: UUID().uuidString)

        let client = try await ClientBuilder()
            .sqliteStore(config: store)
            .userAgent(userAgent: DeviceDescription.userAgent)
            .autoEnableBackups(autoEnableBackups: true)
            .autoEnableCrossSigning(autoEnableCrossSigning: true)
            .encryptionPolicy()
            .withSearchIndexStore(path: search.path(percentEncoded: false), password: UUID().uuidString)
            .homeserverUrl(url: homeserver)
            .slidingSyncVersionBuilder(versionBuilder: .native)
            .build()

        try await client.login(username: username, password: "demo",
                               initialDeviceName: "Iskra (demo)", deviceId: nil)
        return client
    }
}

/// The loopback listener the demo server answers behind. Started once and kept for the life of the
/// process: it costs a socket, and a new port per demo would buy nothing.
actor DemoListener {
    static let shared = DemoListener()

    private var proxy: LocalHTTPProxy?

    func homeserverURL() async throws -> String {
        if let proxy, let url = await proxy.homeserverURL { return url }
        let proxy = LocalHTTPProxy(upstream: MockHomeserver.shared)
        let port = try await proxy.start()
        self.proxy = proxy
        // So the app's own requests (`AccountDevices`) reach the demo server as the SDK's do.
        AuthenticationService.register(standalone: proxy, port: port)
        guard let url = await proxy.homeserverURL else { throw LocalHTTPProxy.ProxyError.notStarted }
        return url
    }
}

extension AuthenticationService {
    /// A signed-in session on the demo server. See `DemoBackend` for what it leaves alone.
    ///
    /// Bounded like every other sign-in, though nothing here reaches the network: a demo that hung
    /// would hang on the launch screen, and that is not a thing to find out by waiting.
    public func startDemoSession() async throws -> UserSession {
        let id = DemoBackend.sessionID
        let data = try environment.sessionDataURL(forSessionID: id)
        let cache = try environment.sessionCachesURL(forSessionID: id)
        let search = try environment.searchIndexURL(forSessionID: id)

        let client = try await withTimeout(.seconds(20)) {
            try await DemoBackend.makeClient(data: data, cache: cache, search: search)
        }
        return await UserSession(client: client, authentication: self, sessionID: DemoBackend.sessionID, isDemo: true,
                                 storageLocations: [.session: data, .cache: cache, .search: search])
    }
}
