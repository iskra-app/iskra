import Foundation
import MatrixRustSDK
import Testing
@testable import IskraCore

/// A whole Matrix session through the bridge — and a stopwatch on every request in it.
///
/// `LiveBridgeTests` proves the tunnel carries a request. This proves it carries a *session*: the
/// real SDK signs in, sliding sync fills the chat list, a room opens and pages in its history, a
/// message goes out and an answer comes back — every byte of it as nostr events on public relays,
/// through a real bridge, to the demo homeserver that lives inside the app.
///
/// ```
/// SDK → listener → NostrTunnelUpstream → relays → iskra-bridge → listener → MockHomeserver
/// ```
///
/// The same session is run twice, once straight at the demo server and once through the bridge,
/// so that what is printed at the end is the tunnel's cost and nothing else. It exists because the
/// next piece of work on the bridge — a sync aggregator — was planned on an assumption about where
/// the time goes, and this is where the time actually goes.
///
/// It spawns its own bridge, because it has to: the bridge must be allowed to reach this process's
/// listener, and that port is chosen at run time. So:
///
/// ```sh
/// (cd Bridge && cargo build -p iskra-bridge)
/// ISKRA_LIVE_BRIDGE_SESSION=1 swift test --filter LiveBridgeSessionTests
/// ```
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["ISKRA_LIVE_BRIDGE_SESSION"] != nil))
struct LiveBridgeSessionTests {
    @Test func aWholeSessionThroughTheBridgeAndWhatItCosts() async throws {
        await MockHomeserver.shared.setReplyDelay(.milliseconds(300))

        // The demo server, on a port of its own — this is what the bridge will be pointed at.
        let server = LocalHTTPProxy(upstream: MockHomeserver.shared)
        let serverPort = try await server.start()
        defer { Task { await server.stop() } }
        let homeserver = URL(string: "http://127.0.0.1:\(serverPort)")!

        // Baseline: the same listener shape, straight at the server.
        let direct = TimedUpstream(MockHomeserver.shared)
        let baseline = try await runSession(through: direct, label: "direct")

        // And through the bridge.
        let bridgeKeys = try NostrKeypair.generate()
        let bridge = try BridgeProcess.start(secret: bridgeKeys.secret,
                                             allowing: homeserver,
                                             relays: TunnelSettings.defaultRelays)
        defer { bridge.stop() }
        try await bridge.waitUntilListening()

        let tunnel = try NostrTunnelUpstream(bridgeKey: bridgeKeys.publicKey,
                                             relays: TunnelSettings.defaultRelays.compactMap(URL.init(string:)),
                                             keys: try TunnelIdentity(secrets: InMemorySecrets()).keypair(),
                                             homeserver: homeserver)
        await tunnel.start()
        defer { Task { await tunnel.stop() } }

        let tunnelled = TimedUpstream(tunnel)
        let bridged = try await runSession(through: tunnelled, label: "bridge")

        print(Report(baseline: baseline, bridged: bridged,
                     direct: await direct.entries, tunnel: await tunnelled.entries))

        // Every sync, in order, for both runs: the one number above that is out of line is a
        // sync, and which one it is says more than the percentile does.
        for (label, entries) in [("direct", await direct.entries), ("bridge", await tunnelled.entries)] {
            guard let origin = entries.first?.started else { continue }
            print("\nsyncs, \(label):  start   took   bytes in")
            for entry in entries where entry.kind.contains("sync") {
                print("  \(Report.ms(entry.started - origin).padding(toLength: 9, withPad: " ", startingAt: 0))"
                      + "\(Report.ms(entry.duration).padding(toLength: 10, withPad: " ", startingAt: 0))"
                      + "\(entry.responseBytes)  \(entry.detail)")
            }
        }
        let logURL = FileManager.default.temporaryDirectory.appending(component: "iskra-bridge-session.log")
        try? bridge.logText.write(to: logURL, atomically: true, encoding: .utf8)
        print("\nbridge log: \(logURL.path(percentEncoded: false))")
    }

    // MARK: - One session

    struct Milestones {
        var label: String
        var signedIn: Duration = .zero
        var chatList: Duration = .zero
        var roomOpen: Duration = .zero
        var sent: Duration = .zero
        var answered: Duration = .zero
        var historyPage: Duration = .zero
    }

    private func runSession(through upstream: TimedUpstream, label: String) async throws -> Milestones {
        let root = FileManager.default.temporaryDirectory.appending(component: "iskra-bridge-session-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let data = root.appending(component: "data")
        let cache = root.appending(component: "cache")
        let search = root.appending(component: "search")
        for url in [data, cache, search] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }

        let listener = LocalHTTPProxy(upstream: upstream)
        let port = try await listener.start()
        defer { Task { await listener.stop() } }

        var milestones = Milestones(label: label)
        let clock = ContinuousClock()
        var mark = clock.now
        func lap() -> Duration {
            let now = clock.now
            defer { mark = now }
            return now - mark
        }

        let store = SqliteStoreBuilder(dataPath: data.path(percentEncoded: false),
                                       cachePath: cache.path(percentEncoded: false))
            .passphrase(passphrase: UUID().uuidString)
        let client = try await ClientBuilder()
            .sqliteStore(config: store)
            .withSearchIndexStore(path: search.path(percentEncoded: false), password: UUID().uuidString)
            .homeserverUrl(url: "http://127.0.0.1:\(port)")
            .slidingSyncVersionBuilder(versionBuilder: .native)
            .build()
        try await client.login(username: DemoBackend.username, password: "demo",
                               initialDeviceName: "Iskra (bridge session)", deviceId: nil)
        milestones.signedIn = lap()

        let list = RoomListStore(client: client)
        try await list.start()
        defer { Task { await list.stop() } }
        let arrived = await eventually(seconds: 60) { list.rooms.count + list.archivedRooms.count >= 9 }
        #expect(arrived, "\(label): rooms \(list.rooms.count)")
        milestones.chatList = lap()

        let room = try #require(list.room(withID: "!anya:iskra.demo"))
        let timeline = TimelineStore(room: room, ownUserID: "@sasha:iskra.demo")
        try await timeline.start()
        defer { timeline.stop() }
        let messages = { timeline.rows.compactMap { row -> Message? in
            if case let .message(message) = row { return message }
            return nil
        } }
        #expect(await eventually(seconds: 60) { messages().count >= 10 }, "\(label): room did not fill")
        milestones.roomOpen = lap()

        let text = "Проверка связи — \(label)"
        let before = messages().count
        await timeline.send(text: text)
        #expect(await eventually(seconds: 60) {
            messages().contains { $0.isOwn && $0.kind == .text(text) && ($0.delivery == .sent || $0.delivery == .read) }
        }, "\(label): not sent")
        milestones.sent = lap()

        #expect(await eventually(seconds: 60) {
            messages().count >= before + 2 && messages().last?.isOwn == false
        }, "\(label): nobody answered")
        milestones.answered = lap()

        let devRoom = try #require(list.room(withID: "!iskra-dev:iskra.demo"))
        let dev = TimelineStore(room: devRoom, ownUserID: "@sasha:iskra.demo")
        try await dev.start()
        defer { dev.stop() }
        _ = await eventually(seconds: 60) { dev.hasLoaded }
        let firstPage = dev.rows.count
        _ = lap()
        await dev.loadMoreHistory()
        #expect(await eventually(seconds: 60) { dev.rows.count > firstPage }, "\(label): no second page")
        milestones.historyPage = lap()

        return milestones
    }

    private func eventually(seconds: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }
}

// MARK: - The stopwatch

/// Every request, how long it took, and what kind it was.
actor TimedUpstream: HTTPUpstream {
    struct Entry: Sendable {
        var kind: String
        var status: Int
        var duration: Duration
        var requestBytes: Int
        var responseBytes: Int
        var started: ContinuousClock.Instant
        /// The query string, which for sync carries `pos` and `timeout` — no identifiers in it.
        var detail: String
    }

    private let inner: any HTTPUpstream
    private(set) var entries: [Entry] = []

    init(_ inner: any HTTPUpstream) { self.inner = inner }

    func send(_ request: ProxiedRequest) async throws -> ProxiedResponse {
        let started = ContinuousClock.now
        let response = try await inner.send(request)
        entries.append(Entry(kind: Self.kind(of: request),
                             status: response.status,
                             duration: started.duration(to: .now),
                             requestBytes: request.body.count,
                             responseBytes: response.body.count,
                             started: started,
                             detail: request.target.split(separator: "?").dropFirst().first.map(String.init) ?? ""))
        return response
    }

    func discovered(homeserver: URL) async {
        await inner.discovered(homeserver: homeserver)
    }

    /// A route without the identifiers in it, so that forty `send`s are one row and not forty.
    static func kind(of request: ProxiedRequest) -> String {
        let path = request.target.split(separator: "?").first.map(String.init) ?? request.target
        if path.contains("simplified_msc3575/sync") {
            let timeout = request.target.contains("timeout=") ? "long-poll" : "immediate"
            return "\(request.method) sync (\(timeout))"
        }
        let segments = path.split(separator: "/").map { segment -> String in
            let text = String(segment).removingPercentEncoding ?? String(segment)
            let isIdentifier = text.hasPrefix("!") || text.hasPrefix("$") || text.hasPrefix("@")
                || text.contains(":") || text.count > 24 || Int(text) != nil
            return isIdentifier ? "*" : text
        }
        return "\(request.method) /" + segments.dropFirst(2).prefix(4).joined(separator: "/")
    }
}

// MARK: - The bridge, as a child process

/// `iskra-bridge`, started for this test and stopped with it.
final class BridgeProcess: @unchecked Sendable {
    private let process = Process()
    private let output = Pipe()
    private let log = LogBuffer()

    static func start(secret: Data, allowing homeserver: URL, relays: [String]) throws -> BridgeProcess {
        let bridge = BridgeProcess()
        let packageRoot = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let binary = packageRoot.appending(path: "Bridge/target/debug/iskra-bridge")
        guard FileManager.default.isExecutableFile(atPath: binary.path(percentEncoded: false)) else {
            throw BridgeProcessError.notBuilt(binary.path(percentEncoded: false))
        }

        bridge.process.executableURL = binary
        var environment = ProcessInfo.processInfo.environment
        environment["BRIDGE_NOSTR_PRIVKEY"] = Hex.string(secret)
        environment["RELAY_LIST"] = relays.joined(separator: ",")
        environment["ALLOWED_UPSTREAMS"] = homeserver.absoluteString
        // A session is dozens of requests in its first seconds, and this is a measurement of the
        // tunnel, not of the rate limit. What the default would have done is printed below.
        environment["RATE_LIMIT_PER_MIN"] = "100000"
        environment["RUST_LOG"] = "info"
        environment["NO_COLOR"] = "1"
        bridge.process.environment = environment
        bridge.process.standardOutput = bridge.output
        bridge.process.standardError = bridge.output

        let log = bridge.log
        bridge.output.fileHandleForReading.readabilityHandler = { handle in
            log.append(handle.availableData)
        }
        try bridge.process.run()
        return bridge
    }

    func waitUntilListening() async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < deadline {
            if log.text.contains("bridge is listening") {
                // Subscribed is not the same as connected; give the relays their handshakes.
                try await Task.sleep(for: .seconds(2))
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw BridgeProcessError.neverListened(log.text)
    }

    var logText: String { log.text }

    func stop() {
        output.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
    }
}

enum BridgeProcessError: Error {
    case notBuilt(String)
    case neverListened(String)
}

final class LogBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        data.append(chunk)
    }

    var text: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - What is printed

struct Report: CustomStringConvertible {
    var baseline: LiveBridgeSessionTests.Milestones
    var bridged: LiveBridgeSessionTests.Milestones
    var direct: [TimedUpstream.Entry]
    var tunnel: [TimedUpstream.Entry]

    var description: String {
        var out = "\n=== A session through the bridge ===\n\n"
        out += "milestone            direct      bridge\n"
        let rows: [(String, KeyPath<LiveBridgeSessionTests.Milestones, Duration>)] = [
            ("signed in", \.signedIn), ("chat list", \.chatList), ("room open", \.roomOpen),
            ("message sent", \.sent), ("answer arrived", \.answered), ("history page", \.historyPage)
        ]
        for (name, path) in rows {
            out += name.padding(toLength: 18, withPad: " ", startingAt: 0)
            out += Self.ms(baseline[keyPath: path]).leftPad(8) + Self.ms(bridged[keyPath: path]).leftPad(12) + "\n"
        }

        out += "\nrequests: direct \(direct.count), bridge \(tunnel.count)\n"
        let span = (tunnel.map(\.started).max() ?? .now) - (tunnel.map(\.started).min() ?? .now)
        out += "through the bridge: \(tunnel.count) requests in \(Self.ms(span)) "
        out += "(the bridge's default allows a burst of 120, then two a second)\n"
        let events = tunnel.reduce(0) { $0 + TunnelChunker.chunkCount(of: $1.requestBytes) }
        out += "request events published: \(events)\n"

        out += "\nthrough the bridge, by kind       n     p50      p95      max    bytes out/in\n"
        let groups = Dictionary(grouping: tunnel, by: \.kind).sorted { $0.value.count > $1.value.count }
        for (kind, entries) in groups {
            let durations = entries.map(\.duration).sorted()
            out += kind.padding(toLength: 32, withPad: " ", startingAt: 0)
            out += "\(entries.count)".leftPad(4)
            out += Self.ms(Self.percentile(durations, 0.5)).leftPad(8)
            out += Self.ms(Self.percentile(durations, 0.95)).leftPad(9)
            out += Self.ms(durations.last ?? .zero).leftPad(9)
            let sent = entries.map(\.requestBytes).reduce(0, +)
            let received = entries.map(\.responseBytes).reduce(0, +)
            out += "    \(sent)/\(received)\n"
        }
        return out
    }

    static func percentile(_ sorted: [Duration], _ p: Double) -> Duration {
        guard !sorted.isEmpty else { return .zero }
        return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))]
    }

    static func ms(_ duration: Duration) -> String {
        "\(Int(duration / .milliseconds(1))) ms"
    }
}

private extension String {
    func leftPad(_ width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }
}
