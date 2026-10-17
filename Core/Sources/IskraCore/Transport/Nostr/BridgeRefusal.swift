import Foundation

/// What the bridge said when it ended a stream, as something the screen can put into words.
///
/// The bridge has one word for every way a stream ends (`StreamReason`, `reason` in
/// `iskra-tunnel-proto/src/stream.rs`). They are not all the same kind of news. Some mean *the
/// bridge will not take you there* — and then the advice is about the bridge's list or the server,
/// never about the address the person typed. One means *the bridge is busy*, which passes. The rest
/// mean the connection broke on the way, which is the network's fault or a bug, and is said as such
/// with the bridge's own word beside it.
///
/// Exhaustive over the words the bridge sends, and `BridgeRefusalTests` holds it to that list: a
/// word added on the Rust side without a case here would reach the screen as "broke" when it means
/// something a person could act on.
public enum BridgeRefusal: Sendable, Equatable {
    /// The server is not on this bridge's list (`ALLOWED_UPSTREAMS`).
    case notAllowed
    /// An open bridge asked the server whether it is a Matrix server, and it did not say yes.
    case notMatrix
    /// The server is on a port other than 443, and the bridge carries 443 only.
    case badPort
    /// The server's address is on a private network, where an open bridge does not go.
    case notPublic
    /// The bridge could not find the server by that name.
    case noSuchHost
    /// The bridge could not connect to the server.
    case unreachable
    /// The bridge has as many streams open as it will hold.
    case busy
    /// The bridge did not recognise what the app sent as TLS for that server — `not tls`, `no sni`,
    /// `sni mismatch`. Never the person's doing: the two programs disagree.
    case disagreement
    /// The stream broke on the way, with the bridge's own word for how.
    case broke(String)

    public init(reason: String) {
        switch reason {
        case StreamReason.notAllowed: self = .notAllowed
        case StreamReason.notMatrix: self = .notMatrix
        case StreamReason.badPort: self = .badPort
        case StreamReason.notPublic: self = .notPublic
        case StreamReason.noSuchHost: self = .noSuchHost
        case StreamReason.unreachable: self = .unreachable
        case StreamReason.busy: self = .busy
        case StreamReason.notTLS, StreamReason.noSNI, StreamReason.sniMismatch: self = .disagreement
        // The bridge raising the price of a connection is a bridge under load; the next `open`
        // pays it without anybody being asked.
        case _ where StreamReason.powRequired(reason) != nil: self = .busy
        default: self = .broke(reason)
        }
    }

    /// The bridge will not take this device to this server — the kind of answer that settles a
    /// sign-in and has nothing to do with the network.
    public var isRefusal: Bool {
        switch self {
        case .notAllowed, .notMatrix, .badPort, .notPublic, .noSuchHost: true
        case .unreachable, .busy, .disagreement, .broke: false
        }
    }
}
