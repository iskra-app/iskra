import Foundation
import Synchronization

/// One HTTP request, as it arrived at the local listener.
public struct ProxiedRequest: Sendable, Equatable {
    public var method: String
    /// Path and query together, exactly as the client wrote them: `/_matrix/client/v3/sync?timeout=0`.
    public var target: String
    public var headers: [String: String]
    public var body: Data

    public init(method: String, target: String, headers: [String: String] = [:], body: Data = Data()) {
        self.method = method
        self.target = target
        self.headers = headers
        self.body = body
    }
}

/// One HTTP response, on its way back to the SDK.
public struct ProxiedResponse: Sendable, Equatable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }
}

/// Where the local listener sends what it receives.
///
/// The seam exists so the listener can be built and proven before the tunnel is: `DirectUpstream`
/// forwards straight to the homeserver over TLS, which answers the question the listener is really
/// being written to answer — whether the SDK will talk plain HTTP to `127.0.0.1` at all. Swapping
/// in the nostr transport later changes this one conformance and nothing else.
public protocol HTTPUpstream: Sendable {
    func send(_ request: ProxiedRequest) async throws -> ProxiedResponse

    /// Told when `.well-known` discovery has revealed where the homeserver really lives.
    ///
    /// Not decoration: discovery is asked of the *delegation* host (`matrix.org`) and answers with
    /// a different one (`matrix-client.matrix.org`), and every request after it belongs to the
    /// second. A transport pinned to the address the user typed would send the whole API to a host
    /// that only ever served one file.
    func discovered(homeserver: URL) async
}

public extension HTTPUpstream {
    func discovered(homeserver: URL) async {}
}

public enum UpstreamError: Error, Sendable {
    case badTarget(String)
    case notHTTP
}

/// Straight to the real homeserver over TLS. No tunnel, no nostr.
public final class DirectUpstream: HTTPUpstream {
    private let base: Mutex<URL>
    private let session: URLSession

    public init(homeserver: URL, session: URLSession = .shared) {
        self.base = Mutex(homeserver)
        self.session = session
    }

    /// Where requests are going right now.
    public var homeserver: URL { base.withLock { $0 } }

    public func discovered(homeserver: URL) async {
        base.withLock { $0 = homeserver }
    }

    public func send(_ request: ProxiedRequest) async throws -> ProxiedResponse {
        guard let url = URL(string: request.target, relativeTo: homeserver) else {
            throw UpstreamError.badTarget(request.target)
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method
        for (name, value) in request.headers where !Self.hopByHop.contains(name.lowercased()) {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        if !request.body.isEmpty {
            urlRequest.httpBody = request.body
        }

        let (data, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else { throw UpstreamError.notHTTP }

        var headers: [String: String] = [:]
        for (name, value) in http.allHeaderFields {
            guard let name = name as? String, let value = value as? String else { continue }
            let lowered = name.lowercased()
            guard !Self.hopByHop.contains(lowered), !Self.decodedAway.contains(lowered) else { continue }
            headers[name] = value
        }
        return ProxiedResponse(status: http.statusCode, headers: headers, body: data)
    }

    /// Headers that describe one hop and must not be carried to the next. `Content-Length` is in
    /// here because both URLSession and the listener frame their own bodies, and a length copied
    /// from the other side of the proxy is the length of a body nobody is sending.
    static let hopByHop: Set<String> = [
        "connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
        "te", "trailer", "transfer-encoding", "upgrade", "content-length", "host"
    ]

    /// Headers describing an encoding URLSession has already undone.
    ///
    /// This one cost a probe run. URLSession asks for gzip and unzips the body before handing it
    /// over, but `allHeaderFields` still says `Content-Encoding: gzip` — so passing it along
    /// announces a compressed body while sending a plain one, and the SDK answers
    /// `ServerUnreachable("error decoding response body")`, which reads like a network fault and
    /// is nothing of the kind. The body is already decoded; the header describing it must go.
    static let decodedAway: Set<String> = ["content-encoding"]
}
