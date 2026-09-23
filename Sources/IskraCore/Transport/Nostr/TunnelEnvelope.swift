import Foundation

/// The JSON that travels inside an encrypted nostr event.
///
/// A mirror of `iskra-tunnel-proto`'s `Envelope`, field for field and name for name — including
/// `body_chunk`, which is spelled the way serde spells it. The two sides of a tunnel that disagree
/// about this structure fail only under load and only in production, so the shape is copied
/// deliberately rather than invented again.
///
/// `method`, `path`, `headers` and `upstream` ride on the first chunk only; `status` likewise on a
/// response. Repeating them would be paid for on every chunk, and bytes are the scarce thing here:
/// a relay's event size limit is the ceiling the whole protocol lives under.
struct TunnelEnvelope: Codable, Equatable {
    static let protocolVersion: UInt8 = 1

    var v: UInt8 = TunnelEnvelope.protocolVersion
    var id: String
    var seq: UInt32
    var total: UInt32

    var method: String?
    var path: String?
    var headers: [String: String]?
    var status: UInt16?
    /// Which homeserver this request is for, as an origin: `https://matrix-client.matrix.org`.
    var upstream: String?

    /// Base64 of this chunk's slice of the body. An empty string for an empty body — never absent.
    var bodyChunk: String

    enum CodingKeys: String, CodingKey {
        case v, id, seq, total, method, path, headers, status, upstream
        case bodyChunk = "body_chunk"
    }

    /// The same refusals the bridge makes, made here too.
    ///
    /// What arrives from a relay arrives from anybody, so this runs on everything inbound.
    func validated() throws -> TunnelEnvelope {
        guard v == Self.protocolVersion else { throw TunnelProtocolError.unsupportedVersion(v) }
        guard total > 0 else { throw TunnelProtocolError.malformed("total is zero") }
        guard seq < total else { throw TunnelProtocolError.malformed("seq is past total") }
        guard !id.isEmpty else { throw TunnelProtocolError.malformed("id is empty") }
        let carriesHead = method != nil || path != nil || status != nil || upstream != nil
        guard !carriesHead || seq == 0 else {
            throw TunnelProtocolError.malformed("head fields on a non-first chunk")
        }
        return self
    }

    var body: Data {
        get throws {
            guard !bodyChunk.isEmpty else { return Data() }
            guard let data = Data(base64Encoded: bodyChunk) else {
                throw TunnelProtocolError.malformed("body is not base64")
            }
            return data
        }
    }
}

enum TunnelProtocolError: Error, Equatable {
    case unsupportedVersion(UInt8)
    case malformed(String)
    /// The bridge could not fit its answer in one envelope. Stage 1 has no chunking, so this is
    /// what a very large response looks like from here.
    case responseTooLarge
}

/// Event kinds, matching `iskra-tunnel-proto`. All in 20000–29999, which relays treat as ephemeral
/// and do not store — the right thing for a tunnel, which leaves no trace by design.
enum TunnelKind {
    static let request = 20_001
    static let response = 20_002
    static let subscribe = 20_003
    static let push = 20_004
    static let config = 20_005
}
