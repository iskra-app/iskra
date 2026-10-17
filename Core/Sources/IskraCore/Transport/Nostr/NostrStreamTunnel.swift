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
    /// NIP-13 bits every `open` is mined to: `defaultPowBits` until the bridge refuses one with
    /// `pow <bits>`, and what it asked for after that. Kept for the life of the tunnel only: a
    /// bridge that raised the price under attack has usually lowered it again by the next launch.
    let pow = PowBits()

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
        let pow = self.pow
        self.carrier = StreamCarrier(link: { frame in
            let bits = frame.op == .open ? pow.bits : 0
            let event = try Self.seal(frame, conversationKey: conversationKey, bridgeKeyHex: bridgeKeyHex,
                                      keys: keys, pow: bits)
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
        let pow = self.pow
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
                if frame.op == .rst, let reason = frame.reason, let bits = StreamReason.powRequired(reason) {
                    pow.bits = bits
                }
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

    /// - Parameter pow: NIP-13 bits to mine to — the `open`'s difficulty, `0` for every other
    ///   frame: segments inside a stream carry none, or a photo would cost hundreds of proofs.
    static func seal(_ frame: StreamFrame, conversationKey: Data, bridgeKeyHex: String,
                     keys: NostrKeypair, pow: UInt8 = 0) throws -> NostrEvent {
        let content = try NIP44.encrypt(frame.wire, conversationKey: conversationKey)
        return try NostrEvent.mined(kind: TunnelKind.streamClient,
                                    content: content,
                                    tags: [["p", bridgeKeyHex]],
                                    bits: pow,
                                    keys: keys)
    }
}

/// The difficulty `open`s are mined to, shared by the link that mines and the dispatcher that hears
/// a bridge ask for more.
final class PowBits: Sendable {
    private let value = Mutex<UInt8>(defaultPowBits)

    var bits: UInt8 {
        get { value.withLock { $0 } }
        set { value.withLock { $0 = newValue } }
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

/// What has been heard from the bridge: for `BridgeCheck`, for the status line, and for telling a
/// sign-in the bridge refused from one the server refused.
final class Heard: Sendable {
    /// The last thing that settled a stream one way or the other.
    enum Last: Sendable, Equatable {
        case opened
        case reset(String)
    }

    private struct State {
        var any = false
        var opened = false
        var last: Last?
        var resets = 0
    }

    private let state = Mutex(State())

    func frame(_ frame: StreamFrame) {
        state.withLock {
            $0.any = true
            switch frame.op {
            case .opened:
                $0.opened = true
                $0.last = .opened
            case .rst:
                if let reason = frame.reason {
                    $0.last = .reset(reason)
                    $0.resets += 1
                }
            default:
                break
            }
        }
    }

    /// Whether any frame at all came back from the bridge.
    var anything: Bool { state.withLock { $0.any } }
    /// Whether the bridge has ever connected a stream — which is what makes it a bridge carrying
    /// this device's TLS, and not merely a key on a relay.
    var everOpened: Bool { state.withLock { $0.opened } }
    /// The last stream to be settled, opened or reset.
    var last: Last? { state.withLock { $0.last } }
    /// The bridge's last word for ending a stream.
    var lastReset: String? {
        state.withLock {
            if case .reset(let reason) = $0.last { return reason }
            return nil
        }
    }

    /// A place to come back to: `refusal(since:)` answers only for what happened after it.
    var mark: Int { state.withLock { $0.resets } }

    /// What the bridge said, if it reset a stream since `mark` and the last word was a refusal.
    func refusal(since mark: Int) -> BridgeRefusal? {
        state.withLock {
            guard $0.resets > mark, case .reset(let reason) = $0.last else { return nil }
            return BridgeRefusal(reason: reason)
        }
    }
}
