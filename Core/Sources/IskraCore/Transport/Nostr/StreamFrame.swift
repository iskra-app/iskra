import Foundation

/// Protocol v2: one frame of a byte stream, as it travels inside a NIP-44 payload.
///
/// A mirror of `iskra-tunnel-proto`'s `StreamFrame`, field for field, and flat on purpose: every
/// field is optional on the wire and `validated()` decides which ones each `op` must and must not
/// have — the same rules, in the same order, as the Rust side. `NostrTunnelTests` pins the JSON as
/// text with the strings `frames_are_exactly_this_json` pins, so a field renamed on one side shows
/// up as a failing test and not as a tunnel that silently never opens.
///
/// In v1 the bridge reads the request, and so the token. Here it carries a TCP connection that the
/// SDK's own TLS runs over, and sees the host, the timing and the byte counts — nothing inside.
struct StreamFrame: Codable, Equatable, Sendable {
    /// `STREAM_PROTOCOL_VERSION`. A v1 bridge never sees one — streams travel on their own kinds —
    /// but a future version is refused here rather than guessed at.
    static let protocolVersion: UInt8 = 2
    /// `MAX_SID_LEN`. A stream id is kept as a key while the stream is open, so its length is
    /// memory whoever sent it chooses; ours is a UUID.
    static let maxIDLength = 64
    /// `MAX_HOST_LEN`: a DNS name's own ceiling.
    static let maxHostLength = 253
    /// `MAX_REASON_LEN`. The reasons are the short words in `StreamReason`.
    static let maxReasonLength = 64
    /// `MAX_SEGMENT`: the largest segment either side accepts, decoded. Senders cut at
    /// `defaultSegment`; this is room above that, and a ceiling on what a stranger can make the
    /// receiver decode.
    static let maxSegment = 64 * 1024
    /// Bytes per segment on the way out: `DEFAULT_SEGMENT`. Base64 inflates it by a third,
    /// the frame adds a little, and NIP-44's own base64 adds a third on top of that — which is why
    /// 24 KiB lands around a 44 KB event, inside the 64 KB limit common on public relays.
    static let defaultSegment = 24 * 1024

    enum Op: String, Codable, Sendable {
        /// Client → bridge: connect to `host:port`, and here are the first bytes (`seq` 0).
        case open
        /// Bridge → client: the TCP connection is up.
        case opened
        /// One segment of the stream.
        case data
        /// Every segment below `ack` has been written to the receiver's socket.
        case ack
        /// No segment at or past `seq` will be sent: the sender's half is closed.
        case fin
        /// The stream is over, with `reason`.
        case rst
    }

    var v: UInt8 = StreamFrame.protocolVersion
    var sid: String
    var op: Op
    var host: String?
    var port: UInt16?
    var seq: UInt32?
    var ack: UInt32?
    /// Base64 of the segment.
    var data: String?
    var reason: String?

    /// The frame as it goes on the wire: serde's field order, absent fields left out, and `/`
    /// unescaped. Written out by hand because `JSONEncoder` promises no key order, and the text is
    /// what the tests pin against the Rust side's — decoding, which cares about none of this, stays
    /// `Codable`.
    var wire: Data {
        var fields = ["\"v\":\(v)", "\"sid\":\(Self.quoted(sid))", "\"op\":\"\(op.rawValue)\""]
        if let host { fields.append("\"host\":\(Self.quoted(host))") }
        if let port { fields.append("\"port\":\(port)") }
        if let seq { fields.append("\"seq\":\(seq)") }
        if let ack { fields.append("\"ack\":\(ack)") }
        if let data { fields.append("\"data\":\(Self.quoted(data))") }
        if let reason { fields.append("\"reason\":\(Self.quoted(reason))") }
        return Data("{\(fields.joined(separator: ","))}".utf8)
    }

    private static func quoted(_ text: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        // A string always encodes; the fallback is never reached and would be refused on arrival.
        return (try? encoder.encode(text)).map { String(decoding: $0, as: UTF8.self) } ?? "\"\""
    }

    static func open(_ sid: String, host: String, port: UInt16, first: Data) -> StreamFrame {
        StreamFrame(sid: sid, op: .open, host: host, port: port, seq: 0, data: first.base64EncodedString())
    }

    static func opened(_ sid: String) -> StreamFrame {
        StreamFrame(sid: sid, op: .opened)
    }

    static func data(_ sid: String, seq: UInt32, bytes: Data) -> StreamFrame {
        StreamFrame(sid: sid, op: .data, seq: seq, data: bytes.base64EncodedString())
    }

    static func ack(_ sid: String, _ ack: UInt32) -> StreamFrame {
        StreamFrame(sid: sid, op: .ack, ack: ack)
    }

    static func fin(_ sid: String, seq: UInt32) -> StreamFrame {
        StreamFrame(sid: sid, op: .fin, seq: seq)
    }

    static func rst(_ sid: String, reason: String) -> StreamFrame {
        StreamFrame(sid: sid, op: .rst, reason: reason)
    }

    /// Refuse anything self-contradictory, before code that assumes a sane frame sees it.
    ///
    /// Each op has the fields it needs and **no others**: a field one side sends and the other
    /// ignores is a field whose meaning drifts. What arrives from a relay arrives from anybody, so
    /// this runs on everything inbound.
    func validated() throws -> StreamFrame {
        guard v == Self.protocolVersion else { throw TunnelProtocolError.unsupportedVersion(v) }
        guard !sid.isEmpty else { throw TunnelProtocolError.malformed("sid is empty") }
        guard sid.utf8.count <= Self.maxIDLength else {
            throw TunnelProtocolError.malformed("sid is too long")
        }

        let needs: (host: Bool, port: Bool, seq: Bool, ack: Bool, data: Bool, reason: Bool)
        switch op {
        case .open: needs = (true, true, true, false, true, false)
        case .opened: needs = (false, false, false, false, false, false)
        case .data: needs = (false, false, true, false, true, false)
        case .ack: needs = (false, false, false, true, false, false)
        case .fin: needs = (false, false, true, false, false, false)
        case .rst: needs = (false, false, false, false, false, true)
        }
        func has(_ present: Bool, _ needed: Bool, _ what: String) throws {
            if needed, !present { throw TunnelProtocolError.malformed(what) }
            if present, !needed { throw TunnelProtocolError.malformed("a field this op does not carry") }
        }
        try has(host != nil, needs.host, "open has no host")
        try has(port != nil, needs.port, "open has no port")
        try has(seq != nil, needs.seq, "no seq")
        try has(ack != nil, needs.ack, "ack has no ack")
        try has(data != nil, needs.data, "no data")
        try has(reason != nil, needs.reason, "rst has no reason")

        if op == .open {
            guard seq == 0 else { throw TunnelProtocolError.malformed("open is not segment 0") }
            let host = host ?? ""
            guard !host.isEmpty, host.utf8.count <= Self.maxHostLength else {
                throw TunnelProtocolError.malformed("host is empty or too long")
            }
            guard port != 0 else { throw TunnelProtocolError.malformed("port is zero") }
        }
        if let reason, reason.utf8.count > Self.maxReasonLength {
            throw TunnelProtocolError.malformed("reason is too long")
        }
        // Base64 is a third longer than what it carries; past this, the decoded segment is past
        // `maxSegment`, and it is refused before anybody decodes it.
        if let data, data.utf8.count > (Self.maxSegment + 2) / 3 * 4 {
            throw TunnelProtocolError.malformed("segment is too large")
        }
        return self
    }

    /// The segment's bytes, decoded. Empty for a frame that carries none.
    var payload: Data {
        get throws {
            guard let data, !data.isEmpty else { return Data() }
            guard let bytes = Data(base64Encoded: data) else {
                throw TunnelProtocolError.malformed("segment is not base64")
            }
            return bytes
        }
    }
}

/// What an `rst` says — `reason` in `stream.rs`, word for word. One word each, the same on both
/// sides, so the app can turn them into a sentence a person can act on: "the bridge will not take
/// you to that server" is a different problem from "the bridge is busy", and both are different
/// from a bridge that is down.
enum StreamReason {
    static let badPort = "bad port"
    static let notPublic = "not public"
    static let notAllowed = "not allowed"
    static let notMatrix = "not matrix"
    static let noSuchHost = "no such host"
    static let notTLS = "not tls"
    static let noSNI = "no sni"
    static let sniMismatch = "sni mismatch"
    static let busy = "busy"
    static let gap = "gap"
    static let window = "window"
    static let `protocol` = "protocol"
    static let unreachable = "unreachable"
    static let upstream = "upstream"
    static let idle = "idle"
    static let expired = "expired"
    static let closed = "closed"
    /// The `open` carried less proof of work than the bridge asks for: sent as `pow <bits>`.
    static let pow = "pow"

    /// The difficulty a `pow <bits>` refusal asks for — `pow_required` in `stream.rs`.
    ///
    /// Past `maxPowBits` the answer is `nil`, as if the bridge had said nothing: a bridge that is
    /// broken or hostile must not be able to set this phone mining until the battery is gone.
    static func powRequired(_ reason: String) -> UInt8? {
        let parts = reason.split(separator: " ")
        guard parts.count == 2, parts[0] == Self.pow, let bits = UInt8(parts[1]),
              bits <= maxPowBits else { return nil }
        return bits
    }
}

/// `DEFAULT_POW_BITS`: what every `open` is mined to until the bridge asks for more.
let defaultPowBits: UInt8 = 16
/// `MAX_POW_BITS`: the most either side accepts. Each bit doubles the work, and 24 is already
/// seconds on a phone, once per connection.
let maxPowBits: UInt8 = 24

enum TunnelProtocolError: Error, Equatable {
    case unsupportedVersion(UInt8)
    case malformed(String)
}

/// Event kinds, matching `iskra-tunnel-proto`. All in 20000–29999, which relays treat as ephemeral
/// and do not store — the right thing for a tunnel, which leaves no trace by design.
///
/// There used to be two more, 20001 and 20002: protocol v1, which handed the bridge the HTTP
/// request itself, token and all. It is gone from both sides, and a bridge no longer listens for it.
enum TunnelKind {
    /// Client → bridge: `StreamFrame`s.
    static let streamClient = 20_010
    /// Bridge → client.
    static let streamBridge = 20_011
}
