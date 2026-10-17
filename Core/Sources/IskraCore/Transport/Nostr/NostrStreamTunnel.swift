import Foundation
import Synchronization

/// The client half of the blind bridge: every connection `LocalConnectProxy` lets through, carried
/// as a stream of encrypted nostr events (protocol v2, kinds 20010 and 20011).
///
/// What goes in is the SDK's own TLS — the bridge connects to the homeserver and moves ciphertext,
/// and sees the host, when, and how many bytes. The protocol before this one handed the bridge
/// each request itself, token and all; it is gone from both sides.
///
/// Two things learnt the hard way with that one still hold:
///
/// - **One dispatcher for every stream.** Events arrive on one subscription and are handed, in the
///   order they came, to the stream their id names. One reader per stream is the quadratic shape
///   the first client had to be rescued from.
/// - **Nothing waits for a relay's `OK`.** A frame is handed to every open socket and that is all;
///   what is waited for is the other side's `ack`. Waiting for acknowledgements "to be sure" is what
///   made a three-chunk answer take twenty seconds on the bridge.
actor NostrStreamTunnel: ConnectUpstream {
    enum Failure: Error, Equatable {
        /// The address in settings is not a nostr public key.
        case bridgeAddressUnusable
    }

    private let keys: NostrKeypair
    private let conversationKey: Data
    private let bridgeKeyHex: String
    private let relays: [URL]
    private let pool: PoolBox
    private let carrier: StreamCarrier
    private var dispatcher: Task<Void, Never>?
    private var events: AsyncStream<NostrEvent>.Continuation?
    /// What the check needs to tell "silent" from "refused": whether the bridge has said anything,
    /// and the last reason it gave for ending a stream.
    let heard = Heard()

    /// - Parameters:
    ///   - bridgeKey: the bridge's 32-byte x-only public key — what it prints at startup.
    ///   - maximumSegment: bytes per segment on the way out — `StreamFrame.defaultSegment`, whose
    ///     arithmetic is what fits one full segment in a public relay's event limit.
    init(bridgeKey: Data, relays: [URL], keys: NostrKeypair,
         maximumSegment: Int = StreamFrame.defaultSegment) throws {
        guard bridgeKey.count == 32 else { throw Failure.bridgeAddressUnusable }
        let conversationKey: Data
        do {
            conversationKey = try NIP44.conversationKey(ourSecret: keys.secret, theirPublicKey: bridgeKey)
        } catch {
            throw Failure.bridgeAddressUnusable
        }
        let bridgeKeyHex = Hex.string(bridgeKey)
        self.keys = keys
        self.conversationKey = conversationKey
        self.bridgeKeyHex = bridgeKeyHex
        self.relays = relays

        let pool = PoolBox()
        self.pool = pool
        self.carrier = StreamCarrier(link: { frame in
            let event = try Self.seal(frame, conversationKey: conversationKey, bridgeKeyHex: bridgeKeyHex, keys: keys)
            guard let relays = pool.current else { throw NostrRelayError.noRelayConnected }
            try await relays.publish(event)
        }, maximumSegment: maximumSegment)
    }

    /// Open the relay connections and subscribe to the bridge's frames. Before the listener, so the
    /// websockets are already shaking hands while the SDK is still being built.
    func start() async {
        guard pool.current == nil else { return }
        let (stream, continuation) = AsyncStream.makeStream(of: NostrEvent.self)
        events = continuation
        let filter = NostrFilter(kinds: [TunnelKind.streamBridge],
                                 authors: [bridgeKeyHex],
                                 recipients: [Hex.string(keys.publicKey)],
                                 since: Int(Date().timeIntervalSince1970) - 60)
        let relays = NostrRelayPool(relays: self.relays, filter: filter) { event in
            continuation.yield(event)
        }
        pool.current = relays
        let carrier = self.carrier
        let conversationKey = self.conversationKey
        let bridgeKeyHex = self.bridgeKeyHex
        let heard = self.heard
        dispatcher = Task.detached(priority: .userInitiated) {
            for await event in stream {
                guard event.pubkey == bridgeKeyHex,
                      let plaintext = try? NIP44.decrypt(event.content, conversationKey: conversationKey),
                      let frame = try? JSONDecoder().decode(StreamFrame.self, from: plaintext).validated()
                else {
                    // Not ours, or not from who it says. Ordinary on an open relay; never worth a
                    // word about what was in it.
                    continue
                }
                heard.frame(frame)
                await carrier.deliver(frame)
            }
        }
        await relays.start()
    }

    func stop() async {
        let relays = pool.current
        pool.current = nil
        await relays?.stop()
        events?.finish()
        events = nil
        dispatcher?.cancel()
        dispatcher = nil
    }

    /// Coming back from the background: see `NostrRelayPool.wake`.
    func wake() async {
        await pool.current?.wake()
    }

    /// Every relay connection dropped at once, the way a long suspension leaves them. For tests.
    func severConnections() async {
        await pool.current?.sever()
    }

    func connectedRelays() async -> Int {
        await pool.current?.connected.count ?? 0
    }

    nonisolated func carry(_ socket: LocalSocket, host: String, port: UInt16, leftover: Data) async {
        let outcome = await carrier.carry(socket, host: host, port: port, leftover: leftover)
        if case let .reset(reason) = outcome {
            // The reason is one of the bridge's short words — never a host, never a byte of what
            // was carried.
            Log.session.info("a bridged stream was reset: \(reason, privacy: .public)")
        }
    }

    static func seal(_ frame: StreamFrame, conversationKey: Data, bridgeKeyHex: String,
                     keys: NostrKeypair) throws -> NostrEvent {
        let content = try NIP44.encrypt(frame.wire, conversationKey: conversationKey)
        return try NostrEvent.signed(kind: TunnelKind.streamClient,
                                     content: content,
                                     tags: [["p", bridgeKeyHex]],
                                     keys: keys)
    }
}

/// The relay pool, reachable from the carrier's link before the tunnel has started — the link is
/// made in `init`, the pool in `start`.
private final class PoolBox: Sendable {
    private let pool = Mutex<NostrRelayPool?>(nil)

    var current: NostrRelayPool? {
        get { pool.withLock { $0 } }
        set { pool.withLock { $0 = newValue } }
    }
}

/// What has been heard from the bridge, for `BridgeCheck`.
final class Heard: Sendable {
    private let state = Mutex<(any: Bool, reset: String?)>((false, nil))

    func frame(_ frame: StreamFrame) {
        state.withLock {
            $0.any = true
            if frame.op == .rst, let reason = frame.reason { $0.reset = reason }
        }
    }

    /// Whether any frame at all came back from the bridge.
    var anything: Bool { state.withLock { $0.any } }
    /// The bridge's last word for ending a stream.
    var lastReset: String? { state.withLock { $0.reset } }
}
