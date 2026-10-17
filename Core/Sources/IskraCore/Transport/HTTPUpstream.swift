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

/// Where the local listener sends what it receives: a homeserver that lives inside the app — the
/// demo server and the sign-in server.
///
/// It used to have a third, the nostr tunnel's first protocol, which handed the bridge each request
/// in the clear. That is gone; the bridge now carries the SDK's own TLS, through
/// `LocalConnectProxy`, and never sees a request at all.
public protocol HTTPUpstream: Sendable {
    func send(_ request: ProxiedRequest) async throws -> ProxiedResponse
}

public enum UpstreamError: Error, Sendable {
    case badTarget(String)
    case notHTTP
}

/// One request of the app's own to the real homeserver over TLS — for the few calls the SDK does
/// not export (`AccountDevices`). Straight there, or through the bridge's `CONNECT` listener when
/// it is given that listener's session (`AuthenticationService.send(_:toHomeserver:)`).
public final class DirectUpstream: HTTPUpstream {
    /// Where requests go.
    public let homeserver: URL
    private let session: URLSession

    public init(homeserver: URL, session: URLSession = DirectUpstream.privateSession) {
        self.homeserver = homeserver
        self.session = session
    }

    /// A session that remembers nothing. `URLSession.shared` has the shared `URLCache` — a
    /// plaintext `Cache.db` on the disk, holding whatever a homeserver marked cacheable (media from
    /// unencrypted rooms, avatars, profiles) beside a store that is encrypted at rest on purpose —
    /// and the shared cookie jar, which a homeserver has no business writing into.
    public static let privateSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration)
    }()

    public func send(_ request: ProxiedRequest) async throws -> ProxiedResponse {
        // A path, and only a path. `URL(string:relativeTo:)` resolves `//elsewhere/x` and
        // `http://elsewhere/x` to *elsewhere* — and the listener this sits behind is reachable by
        // every process on the machine, so that was an open proxy wearing this app's address.
        let homeserver = self.homeserver
        guard request.target.hasPrefix("/"), !request.target.hasPrefix("//"),
              let url = URL(string: request.target, relativeTo: homeserver),
              url.host() == homeserver.host(), url.port == homeserver.port
        else {
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

        let (data, response) = try await session.data(for: urlRequest,
                                                      delegate: SameHostRedirects(host: homeserver.host()))
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

/// Follows a redirect only while it stays on the homeserver's host. One that leaves is handed
/// back as the 3xx it was, rather than followed here with the request's `Authorization` still on
/// it — URLSession does not promise to take a header we set ourselves off a cross-host hop.
private final class SameHostRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    private let host: String?

    init(host: String?) { self.host = host }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        request.url?.host() == host ? request : nil
    }
}
