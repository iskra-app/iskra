import Foundation

/// Cutting one HTTP message into envelopes, the way `iskra-tunnel-proto`'s chunker cuts it.
///
/// The two are the same program written twice, which is a thing to be uncomfortable about — so the
/// rules are stated in one sentence each here and pinned by tests on both sides. A client that cuts
/// a body one way and a bridge that puts it back together another way fails only under load, only
/// sometimes, and only in production.
///
/// - An empty body is **one** chunk, not none. A request with nothing in it is still a request.
/// - The head fields (`method`, `path`, `headers`, `upstream`, `status`) ride on chunk 0 alone, and
///   an envelope that carries them anywhere else is refused by both ends.
/// - The budget is counted in *body* bytes. Base64 inflates a chunk by a third, the JSON envelope
///   adds a little, and NIP-44's own base64 adds a third on top of that — which is why 24 KiB of
///   body lands around a 44 KB event, inside the 64 KB limit common on public relays.
public enum TunnelChunker {
    /// Raw body bytes per chunk. The bridge's own default, and the number its `MAX_BODY_CHUNK`
    /// changes; a client that guessed differently would still work, because the count travels in
    /// `total` rather than being inferred.
    public static let defaultMaxBodyChunk = 24 * 1024

    static func envelopes(id: String,
                          method: String,
                          path: String,
                          headers: [String: String],
                          upstream: String?,
                          body: Data,
                          maxBodyChunk: Int = defaultMaxBodyChunk) -> [TunnelEnvelope] {
        slices(of: body, maxBodyChunk: maxBodyChunk).enumerated().map { seq, part in
            TunnelEnvelope(id: id,
                           seq: UInt32(seq),
                           total: UInt32(chunkCount(of: body.count, maxBodyChunk: maxBodyChunk)),
                           method: seq == 0 ? method : nil,
                           path: seq == 0 ? path : nil,
                           headers: seq == 0 ? headers : nil,
                           status: nil,
                           upstream: seq == 0 ? upstream : nil,
                           bodyChunk: part.base64EncodedString())
        }
    }

    /// The same, for an answer. Only the tests send one of these — the bridge is what answers in
    /// life — and they are what proves this side agrees with itself.
    static func envelopes(id: String,
                          status: UInt16,
                          headers: [String: String],
                          body: Data,
                          maxBodyChunk: Int = defaultMaxBodyChunk) -> [TunnelEnvelope] {
        slices(of: body, maxBodyChunk: maxBodyChunk).enumerated().map { seq, part in
            TunnelEnvelope(id: id,
                           seq: UInt32(seq),
                           total: UInt32(chunkCount(of: body.count, maxBodyChunk: maxBodyChunk)),
                           method: nil,
                           path: nil,
                           headers: seq == 0 ? headers : nil,
                           status: seq == 0 ? status : nil,
                           upstream: nil,
                           bodyChunk: part.base64EncodedString())
        }
    }

    static func chunkCount(of length: Int, maxBodyChunk: Int = defaultMaxBodyChunk) -> Int {
        let budget = max(maxBodyChunk, 1)
        return max(length.isMultiple(of: budget) ? length / budget : length / budget + 1, 1)
    }

    private static func slices(of body: Data, maxBodyChunk: Int) -> [Data] {
        let budget = max(maxBodyChunk, 1)
        guard !body.isEmpty else { return [Data()] }
        return stride(from: 0, to: body.count, by: budget).map { start in
            let end = min(start + budget, body.count)
            return body.subdata(in: (body.startIndex + start)..<(body.startIndex + end))
        }
    }
}
