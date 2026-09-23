import Foundation
import OSLog

/// The client half of the bridge: every HTTP request the SDK makes, wrapped in an encrypted nostr
/// event and published to relays, with the answer coming back the same way.
///
/// It sits exactly where `DirectUpstream` sits — behind `LocalHTTPProxy`, which is what puts the
/// SDK's requests in front of us in the clear — so nothing above the transport knows the
/// difference. The loopback listener terminates the SDK's plain HTTP; real TLS to the homeserver
/// is terminated at the bridge, on the far side.
///
/// One dispatcher, not one reader per request: responses arrive on a single stream from the pool
/// and are matched to the one caller waiting on that envelope id. The Rust client is built the
/// same way, and for the same reason — giving every in-flight request its own reader makes the
/// work quadratic in requests in flight and loses answers under load.
public actor NostrTunnelUpstream: HTTPUpstream {
    public enum Failure: Error, Equatable {
        /// The address in settings is not a nostr public key.
        case bridgeAddressUnusable
        /// No relay took the request: every one of them is down or unreachable.
        case noRelayConnected
        /// The bridge did not answer inside the limit.
        case noAnswer(Duration)
        /// Stage 1 carries one envelope per message. A bridge that chunks is a newer bridge.
        case chunkedResponseUnsupported
        /// The answer decrypted, and was not a well-formed response.
        case malformedResponse(String)
    }

    private let keys: NostrKeypair
    private let bridgeKey: Data
    private let bridgeKeyHex: String
    private let conversationKey: Data
    private let relays: [URL]
    private let limit: Duration
    private let log = Logger(subsystem: "moscow.swag.iskra", category: "tunnel")

    private var homeserver: URL
    private var pool: NostrRelayPool?
    /// Who is waiting for which envelope id.
    private var pending: [String: CheckedContinuation<ProxiedResponse, any Error>] = [:]
    /// The timer that gives up on each of them.
    private var deadlines: [String: Task<Void, Never>] = [:]

    /// - Parameters:
    ///   - bridgeKey: the bridge's 32-byte x-only public key — what it prints at startup.
    ///   - homeserver: where the requests are ultimately going. It travels *in* each request, not
    ///     in the bridge's configuration, because discovery and the API live on different hosts.
    ///   - limit: how long to wait for an answer. Longer than the bridge's own request timeout on
    ///     purpose: when the homeserver is the thing that is stuck, the bridge's own answer says so
    ///     and is worth more than a timeout invented here.
    public init(bridgeKey: Data,
                relays: [URL],
                keys: NostrKeypair,
                homeserver: URL,
                limit: Duration = .seconds(90)) throws {
        guard bridgeKey.count == 32 else { throw Failure.bridgeAddressUnusable }
        self.keys = keys
        self.bridgeKey = bridgeKey
        self.bridgeKeyHex = Hex.string(bridgeKey)
        self.relays = relays
        self.homeserver = homeserver
        self.limit = limit
        do {
            self.conversationKey = try NIP44.conversationKey(ourSecret: keys.secret,
                                                             theirPublicKey: bridgeKey)
        } catch {
            throw Failure.bridgeAddressUnusable
        }
    }

    /// Open the relay connections and subscribe to answers.
    ///
    /// Called before the SDK is pointed at the listener, so that the first request does not have
    /// to wait for a websocket handshake — though it would survive that, since a request published
    /// before any relay is up fails with `noRelayConnected` rather than disappearing.
    public func start() async {
        guard pool == nil else { return }
        let filter = NostrFilter(kinds: [TunnelKind.response],
                                 authors: [bridgeKeyHex],
                                 recipients: [Hex.string(keys.publicKey)],
                                 since: Int(Date().timeIntervalSince1970) - 60)
        let pool = NostrRelayPool(relays: relays, filter: filter) { [weak self] event in
            Task { await self?.accept(event) }
        }
        self.pool = pool
        await pool.start()
    }

    public func stop() async {
        await pool?.stop()
        pool = nil
        for (_, deadline) in deadlines { deadline.cancel() }
        deadlines.removeAll()
        for (_, waiting) in pending { waiting.resume(throwing: Failure.noRelayConnected) }
        pending.removeAll()
    }

    /// Relays with a live connection, for the settings screen to show.
    public func connectedRelays() async -> Int {
        await pool?.connected.count ?? 0
    }

    public var publicKey: String { keys.npub }

    public func discovered(homeserver: URL) async {
        self.homeserver = homeserver
    }

    // MARK: - HTTPUpstream

    public func send(_ request: ProxiedRequest) async throws -> ProxiedResponse {
        let id = UUID().uuidString
        var headers: [String: String] = [:]
        for (name, value) in request.headers where !DirectUpstream.hopByHop.contains(name.lowercased()) {
            headers[name] = value
        }

        let envelope = TunnelEnvelope(id: id,
                                      seq: 0,
                                      total: 1,
                                      method: request.method,
                                      path: request.target,
                                      headers: headers,
                                      status: nil,
                                      upstream: Self.origin(of: homeserver),
                                      bodyChunk: request.body.base64EncodedString())

        let event = try seal(envelope)

        return try await withCheckedThrowingContinuation { continuation in
            // Registered before the event goes out. The other order is a race the bridge wins
            // often enough on a fast relay to make the bug look intermittent.
            pending[id] = continuation
            deadlines[id] = Task { [limit] in
                try? await Task.sleep(for: limit)
                self.giveUp(on: id)
            }
            Task { await self.publish(event, for: id) }
        }
    }

    // MARK: - Sending

    private func seal(_ envelope: TunnelEnvelope) throws -> NostrEvent {
        let encoder = JSONEncoder()
        let json = try encoder.encode(envelope)
        let content = try NIP44.encrypt(json, conversationKey: conversationKey)
        return try NostrEvent.signed(kind: TunnelKind.request,
                                     content: content,
                                     tags: [["p", bridgeKeyHex]],
                                     keys: keys)
    }

    private func publish(_ event: NostrEvent, for id: String) async {
        guard let pool else { return finish(id, with: .failure(Failure.noRelayConnected)) }
        do {
            try await pool.publish(event)
        } catch {
            finish(id, with: .failure(Failure.noRelayConnected))
        }
    }

    // MARK: - Receiving

    /// One event from the pool: decrypt it, and give it to whoever is waiting for it.
    private func accept(_ event: NostrEvent) {
        guard event.pubkey == bridgeKeyHex else { return }
        guard let plaintext = try? NIP44.decrypt(event.content, conversationKey: conversationKey),
              let envelope = try? JSONDecoder().decode(TunnelEnvelope.self, from: plaintext).validated()
        else {
            // Not ours, or not from who it says. Ordinary on an open relay; never worth a word
            // about what was in it.
            return
        }

        guard envelope.total == 1 else {
            return finish(envelope.id, with: .failure(Failure.chunkedResponseUnsupported))
        }
        guard let status = envelope.status else {
            return finish(envelope.id, with: .failure(Failure.malformedResponse("no status")))
        }
        guard let body = try? envelope.body else {
            return finish(envelope.id, with: .failure(Failure.malformedResponse("body is not base64")))
        }

        finish(envelope.id, with: .success(ProxiedResponse(status: Int(status),
                                                           headers: envelope.headers ?? [:],
                                                           body: body)))
    }

    private func giveUp(on id: String) {
        guard pending[id] != nil else { return }
        log.warning("no answer through the bridge within \(self.limit.components.seconds)s")
        finish(id, with: .failure(Failure.noAnswer(limit)))
    }

    /// Hand one waiter its result, once.
    ///
    /// Relays fan out, so the same answer arrives once per relay; the pool drops the duplicates by
    /// event id, and removing the waiter here is what makes a duplicate that slips through — a
    /// bridge that answered twice, say — harmless rather than a crash on a continuation resumed
    /// for the second time.
    private func finish(_ id: String, with result: Result<ProxiedResponse, any Error>) {
        deadlines.removeValue(forKey: id)?.cancel()
        guard let waiting = pending.removeValue(forKey: id) else { return }
        waiting.resume(with: result)
    }

    /// `https://matrix-client.matrix.org` — scheme, host and port, and nothing else. The bridge
    /// compares origins, and a path here would simply be dropped.
    static func origin(of url: URL) -> String {
        var origin = (url.scheme ?? "https") + "://" + (url.host() ?? "")
        if let port = url.port { origin += ":\(port)" }
        return origin
    }
}
