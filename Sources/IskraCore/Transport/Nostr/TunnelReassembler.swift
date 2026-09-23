import Foundation

/// Putting the chunks of one answer back together.
///
/// The mirror of `iskra-tunnel-proto`'s `Reassembler`, and written with the same suspicion: what
/// arrives here arrives from a relay, which is to say from anybody. Three things follow, and none
/// of them are optional.
///
/// - **Duplicates are normal.** An answer is published to every relay and comes back from every
///   relay. `NostrRelayPool` drops the repeats it can recognise by event id, but a bridge that
///   answered twice, or a relay that re-delivered after a reconnect, gets here — so a chunk that
///   arrives twice must count once.
/// - **Partial messages live in memory, so they are capped** — in chunks, in bytes, in how many may
///   be open at once, and in how long one may stay open. On a phone this matters more than it does
///   on the bridge: an uncapped reassembler is a way for anybody who knows this device's key to
///   make it hold megabytes it will never finish.
/// - **Nothing is assumed about order.** Chunk 7 may arrive before chunk 0, which means the status
///   and the headers may not be there yet when a body chunk is.
struct TunnelReassembler {
    struct Limits: Sendable {
        var maxChunks: UInt32 = 512
        var maxBytes = 8 * 1024 * 1024
        var maxInFlight = 64
        var ttl: Duration = .seconds(60)
    }

    enum Accepted {
        /// Every chunk is in: the head envelope, and the body it describes.
        case complete(head: TunnelEnvelope, body: Data)
        /// Taken, and waiting for the rest.
        case waiting
        /// Dropped, with the reason — for the log, and for the caller waiting on that id.
        case refused(String)
    }

    private struct Partial {
        var total: UInt32
        /// By sequence number. `nil` until that chunk arrives, which is also how a duplicate is
        /// recognised: the slot is already full.
        var chunks: [Data?]
        var head: TunnelEnvelope?
        var bytes: Int
        var arrived: UInt32
        var started: ContinuousClock.Instant
    }

    private var partials: [String: Partial] = [:]
    private let limits: Limits

    init(limits: Limits = Limits()) {
        self.limits = limits
    }

    var inFlight: Int { partials.count }

    /// Take one chunk.
    ///
    /// `now` is passed in rather than read here so the expiry rule can be tested without waiting
    /// a minute for it.
    mutating func accept(_ envelope: TunnelEnvelope,
                         key: String,
                         now: ContinuousClock.Instant = .now) -> Accepted {
        guard let envelope = try? envelope.validated() else { return .refused("malformed envelope") }
        expire(now)

        guard let body = try? envelope.body else { return .refused("body is not base64") }

        // The common case, and the one worth keeping cheap: a whole message in one chunk never
        // touches the table at all.
        if envelope.total == 1 {
            return .complete(head: envelope, body: body)
        }
        guard envelope.total <= limits.maxChunks else { return .refused("too many chunks") }

        guard var partial = partials[key] else {
            guard partials.count < limits.maxInFlight else {
                // Refusing the new one rather than evicting an old one: eviction would let a
                // stranger flush an answer this device was halfway through receiving.
                return .refused("too many messages in flight")
            }
            guard body.count <= limits.maxBytes else { return .refused("message is too large") }
            var chunks = [Data?](repeating: nil, count: Int(envelope.total))
            chunks[Int(envelope.seq)] = body
            partials[key] = Partial(total: envelope.total,
                                    chunks: chunks,
                                    head: envelope.seq == 0 ? envelope : nil,
                                    bytes: body.count,
                                    arrived: 1,
                                    started: now)
            return .waiting
        }

        guard partial.total == envelope.total else {
            // The same message id with two different lengths. One of them is a lie.
            partials[key] = nil
            return .refused("total changed mid-message")
        }
        guard partial.chunks[Int(envelope.seq)] == nil else {
            // Already had this one. Ordinary, and already counted.
            return .waiting
        }
        guard partial.bytes + body.count <= limits.maxBytes else {
            partials[key] = nil
            return .refused("message is too large")
        }

        partial.chunks[Int(envelope.seq)] = body
        partial.bytes += body.count
        partial.arrived += 1
        if envelope.seq == 0 { partial.head = envelope }

        guard partial.arrived == partial.total else {
            partials[key] = partial
            return .waiting
        }
        partials[key] = nil
        return finish(partial)
    }

    /// Give up on one message — what the caller does when its own deadline passes, so that an
    /// answer nobody is waiting for any more does not sit in memory until the TTL.
    mutating func forget(_ key: String) {
        partials[key] = nil
    }

    private func finish(_ partial: Partial) -> Accepted {
        // A message whose chunk 0 never arrived has no status and no headers, so there is nothing
        // to hand back even though every byte is here.
        guard let head = partial.head else { return .refused("no head chunk") }
        var body = Data(capacity: partial.bytes)
        for chunk in partial.chunks {
            guard let chunk else { return .refused("a chunk went missing") }
            body.append(chunk)
        }
        return .complete(head: head, body: body)
    }

    private mutating func expire(_ now: ContinuousClock.Instant) {
        let ttl = limits.ttl
        partials = partials.filter { now - $0.value.started < ttl }
    }
}
