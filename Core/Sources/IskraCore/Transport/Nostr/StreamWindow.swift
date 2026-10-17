import Foundation

/// The numbers of protocol v2, `stream.rs`'s constants one for one.
enum StreamLimits {
    /// Most unacknowledged bytes a sender may have out. About forty segments: a relay kept busy,
    /// and neither side holding somebody's download in memory.
    static let windowBytes = 1024 * 1024
    /// Most unacknowledged segments, whatever their size. Without it a sender flushing a few bytes
    /// at a time could have tens of thousands in the air inside the byte window, and the receiver
    /// would hold every one of them past a hole.
    static let windowSegments: UInt32 = 64
    /// The receiver acknowledges at least this often, in segments written to its socket…
    static let ackEverySegments: UInt32 = 8
    /// …or in bytes, whichever comes first. Both well inside the window: an acknowledgement that
    /// waited for the window to fill would never be sent, because the sender stops when it fills.
    static let ackEveryBytes = 256 * 1024
    /// How long a hole is waited on before the stream is reset. Relays do not store ephemeral
    /// events, so a segment no relay delivered is never coming.
    static let gapTimeout: Duration = .seconds(5)
    /// How long a socket may say nothing before what it has said goes out as a segment. One event
    /// per read would be hundreds of events per room load, and a public relay bans that.
    static let coalesce: Duration = .milliseconds(5)
}

/// Something the other side did that a correct implementation never does. The stream is reset —
/// never quietly carried on, because two ends that disagree about what was said deliver somebody's
/// bytes in the wrong order.
enum StreamViolation: Error, Equatable {
    /// A segment past the window this side gave.
    case beyondWindow
    /// A segment at or past the `fin` already received.
    case dataAfterFin
    /// A second `fin` that disagrees with the first, or one below what was already delivered.
    case finMoved
    /// An `ack` for a segment that was never sent.
    case ackBeyondSent

    /// The `rst` reason it becomes.
    var reason: String {
        self == .beyondWindow ? StreamReason.window : StreamReason.protocol
    }
}

/// The sending half's window — `Outbound` in `stream.rs`.
///
/// Moved only by acknowledgements, and an acknowledgement says what the far side has *written to
/// its socket*. So what this side reads from its own socket is never more than the far socket has
/// accepted, and that is the whole of the back-pressure: a sender with a full window stops reading,
/// and TCP tells whoever is writing to slow down.
struct StreamOutbound: Equatable {
    private(set) var nextSeq: UInt32 = 0
    /// Every segment below this has been acknowledged.
    private var acked: UInt32 = 0
    /// Sizes of the segments in `acked..<nextSeq`, oldest first.
    private var unacked: [Int] = []
    private(set) var unackedBytes = 0

    init() {}

    /// A sender whose segment 0 already went out with `open`, `firstLength` bytes long.
    static func afterOpen(_ firstLength: Int) -> StreamOutbound {
        var outbound = StreamOutbound()
        outbound.push(firstLength)
        return outbound
    }

    /// Whether a segment of `length` bytes may go out now.
    ///
    /// An empty window always admits one segment, whatever its size: a segment larger than the
    /// window would otherwise never be sent, and the stream would stall with nothing to explain it.
    func hasRoom(_ length: Int) -> Bool {
        if unacked.isEmpty { return true }
        return UInt32(unacked.count) < StreamLimits.windowSegments
            && unackedBytes + length <= StreamLimits.windowBytes
    }

    /// Whether *any* segment may go out — what a sender asks before reading its socket at all.
    var isOpen: Bool { hasRoom(0) }

    /// Account for one segment going out; its `seq`.
    @discardableResult
    mutating func push(_ length: Int) -> UInt32 {
        let seq = nextSeq
        nextSeq += 1
        unacked.append(length)
        unackedBytes += length
        return seq
    }

    /// Take an acknowledgement. An old one, arriving late from a slow relay, changes nothing.
    mutating func ack(_ ack: UInt32) throws(StreamViolation) {
        guard ack <= nextSeq else { throw .ackBeyondSent }
        while acked < ack {
            unackedBytes -= unacked.removeFirst()
            acked += 1
        }
    }
}

/// The receiving half — `Inbound` in `stream.rs`: segments in, the contiguous prefix out.
///
/// Segments arrive out of order and once per relay, and only the contiguous prefix goes to the
/// socket. The questions `stream.rs`'s tests ask of it are asked of this one in `StreamWindowTests`,
/// case for case.
struct StreamInbound {
    typealias Instant = ContinuousClock.Instant

    /// The next `seq` the socket is waiting for. Everything below it has been handed out.
    private var next: UInt32 = 0
    /// Segments past a hole, held until it fills.
    private var held: [UInt32: Data] = [:]
    private var heldBytes = 0
    private var fin: UInt32?
    /// Since when something has been waiting on a hole. Nil while nothing is.
    private var holeSince: Instant?

    /// Segments the owner has reported written to its socket — what `ack` says.
    private var written: UInt32 = 0
    /// Bytes handed out by `accept` and not yet reported written: the owner's queue to its socket.
    private var unwrittenBytes = 0
    private var unackedSegments: UInt32 = 0
    private var unackedBytes = 0

    init() {}

    /// Take one segment. Returns whatever is now contiguous, in order, for the socket — possibly
    /// nothing (a duplicate, or a segment past a hole), possibly several (the one that filled it).
    mutating func accept(_ seq: UInt32, _ bytes: Data, now: Instant) throws(StreamViolation) -> [Data] {
        // Every relay delivers its own copy. Ordinary, and already counted.
        if seq < next || held[seq] != nil { return [] }
        if let fin, seq >= fin { throw .dataAfterFin }
        // Measured from what has been *written*, not from what has been assembled: the sender's
        // window starts at its last acknowledgement, which is never past `written`. Measured from
        // `next`, a sender ignoring acknowledgements could keep the prefix moving and pile up
        // everything in front of a slow socket — held nowhere here, and so capped by nothing.
        let (sum, overflow) = written.addingReportingOverflow(StreamLimits.windowSegments)
        let limit = overflow ? UInt32.max : sum // `saturating_add`
        if seq >= limit
            || heldBytes + unwrittenBytes + bytes.count > StreamLimits.windowBytes + StreamFrame.maxSegment {
            throw .beyondWindow
        }

        var ready: [Data] = []
        if seq == next {
            ready.append(bytes)
            next += 1
            while let following = held.removeValue(forKey: next) {
                heldBytes -= following.count
                ready.append(following)
                next += 1
            }
            unwrittenBytes += ready.reduce(0) { $0 + $1.count }
        } else {
            heldBytes += bytes.count
            held[seq] = bytes
        }
        updateHole(progressed: !ready.isEmpty, now: now)
        return ready
    }

    /// Take the other side's `fin`. True when the stream in this direction is now complete.
    mutating func finish(_ seq: UInt32, now: Instant) throws(StreamViolation) -> Bool {
        if let fin {
            guard fin == seq else { throw .finMoved }
            return isComplete
        }
        // A `fin` below what was already delivered, or below a segment already held, says that
        // bytes which exist were never sent.
        if seq < next || (held.keys.max().map { $0 >= seq } ?? false) { throw .finMoved }
        fin = seq
        updateHole(progressed: false, now: now)
        return isComplete
    }

    /// Every segment up to the `fin` has been handed out.
    var isComplete: Bool { fin == next }

    /// Whether a hole has been waited on longer than the gap timeout.
    func gapExpired(now: Instant) -> Bool {
        holeSince.map { now - $0 >= StreamLimits.gapTimeout } ?? false
    }

    /// When the hole being waited on will have been waited on too long, if there is one.
    var gapDeadline: Instant? {
        holeSince.map { $0 + StreamLimits.gapTimeout }
    }

    /// Report segments written to the socket. Returns the `ack` to send, when one is due.
    ///
    /// Acknowledged once *written*, not once received: that is what makes the window mean "what the
    /// far socket has accepted", and so what carries TCP's back-pressure across the tunnel.
    mutating func written(segments: UInt32, bytes: Int) -> UInt32? {
        written += segments
        unwrittenBytes = max(unwrittenBytes - bytes, 0)
        unackedSegments += segments
        unackedBytes += bytes
        guard unackedSegments >= StreamLimits.ackEverySegments || unackedBytes >= StreamLimits.ackEveryBytes else {
            return nil
        }
        unackedSegments = 0
        unackedBytes = 0
        return written
    }

    /// A hole is anything held past `next`, or a `fin` that `next` has not reached. The clock starts
    /// when one appears and starts again whenever the prefix moves, so a slow stream that keeps
    /// making progress is never mistaken for a broken one.
    private mutating func updateHole(progressed: Bool, now: Instant) {
        let waiting = !held.isEmpty || (fin.map { $0 > next } ?? false)
        if !waiting {
            holeSince = nil
        } else if holeSince == nil || progressed {
            holeSince = now
        }
    }
}
