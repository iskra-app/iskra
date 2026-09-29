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
        /// The answer decrypted, and was not a well-formed response — including an answer too big
        /// for the ceilings in `TunnelReassembler.Limits`.
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
    /// Answers that have not finished arriving.
    private var partials = TunnelReassembler()
    /// Body bytes per chunk on the way out. The bridge's `MAX_BODY_CHUNK` decides nothing here —
    /// the count travels in `total`, so the two sides need not agree on the size, only on the
    /// arithmetic.
    private let maxBodyChunk: Int
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
                limit: Duration = .seconds(90),
                maxBodyChunk: Int = TunnelChunker.defaultMaxBodyChunk) throws {
        guard bridgeKey.count == 32 else { throw Failure.bridgeAddressUnusable }
        self.maxBodyChunk = maxBodyChunk
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

    /// Coming back from the background: check the relays now rather than when a request finds out.
    /// See `NostrRelayPool.wake`.
    public func wake() async {
        await pool?.wake()
    }

    /// Every relay connection dropped at once, the way a long suspension leaves them. For tests.
    func severConnections() async {
        await pool?.sever()
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

        // As many events as the body takes. A photo is not a special case here, it is simply a
        // request with two hundred chunks in it.
        let events = try TunnelChunker.envelopes(id: id,
                                                 method: request.method,
                                                 path: request.target,
                                                 headers: headers,
                                                 upstream: Self.origin(of: homeserver),
                                                 body: request.body,
                                                 maxBodyChunk: maxBodyChunk)
            .map { try seal($0) }

        return try await withCheckedThrowingContinuation { continuation in
            // Registered before the events go out. The other order is a race the bridge wins
            // often enough on a fast relay to make the bug look intermittent.
            pending[id] = continuation
            deadlines[id] = Task { [limit] in
                try? await Task.sleep(for: limit)
                self.giveUp(on: id)
            }
            Task { await self.publish(events, for: id) }
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

    /// Publish every chunk of one request.
    ///
    /// In order and one at a time, though the order is not what makes it work — the bridge
    /// reassembles out of order anyway. It is that a relay is a websocket: a hundred `send`s are a
    /// hundred frames down one connection, not a hundred round trips.
    private func publish(_ events: [NostrEvent], for id: String) async {
        guard let pool else { return finish(id, with: .failure(Failure.noRelayConnected)) }
        for event in events {
            do {
                try await pool.publish(event)
            } catch {
                return finish(id, with: .failure(Failure.noRelayConnected))
            }
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

        // Nobody is waiting for it: an answer to a request already answered, or one a relay kept
        // and is playing back. Dropped before the reassembler sees it — replayed pieces of old
        // answers used to fill its sixty-four slots, and every real answer bigger than one event
        // was then refused as "too many in flight".
        guard pending[envelope.id] != nil else { return }

        // An answer may arrive in pieces, from several relays, in any order.
        let head: TunnelEnvelope
        let body: Data
        switch partials.accept(envelope, key: envelope.id) {
        case .complete(let complete, let bytes):
            (head, body) = (complete, bytes)
        case .waiting:
            return
        case .refused(let reason):
            return finish(envelope.id, with: .failure(Failure.malformedResponse(reason)))
        }

        guard let status = head.status else {
            return finish(head.id, with: .failure(Failure.malformedResponse("no status")))
        }
        finish(head.id, with: .success(ProxiedResponse(status: Int(status),
                                                       headers: head.headers ?? [:],
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
        // Whatever had arrived of this answer goes with it. Waiting for the reassembler's own TTL
        // would hold a half-arrived megabyte for a minute after nobody wanted it any more.
        partials.forget(id)
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
