import Foundation
import Testing

@testable import IskraCore

/// Plays the browser: loads a URL and hands back where it was redirected, without following it.
/// The redirect is to `moscow.swag.iskra:`, which nothing here could follow anyway — in the app
/// that is the moment `ASWebAuthenticationSession` catches it.
private final class Browser: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? { nil }

    /// Fills in the page's form the way a person would and presses its button.
    func submit(_ page: URL, username: String, password: String) async throws -> (status: Int, location: URL?, body: String) { // swiftlint:disable:this large_tuple
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)

        let (html, _) = try await session.data(from: page)
        let fields = Self.hiddenFields(in: String(bytes: html, encoding: .utf8) ?? "")

        var approve = try #require(URLComponents(url: page, resolvingAgainstBaseURL: false))
        approve.path = "/_mock/oauth/approve"
        approve.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
            + [URLQueryItem(name: "username", value: username), URLQueryItem(name: "password", value: password)]

        let (data, response) = try await session.data(from: try #require(approve.url))
        let http = try #require(response as? HTTPURLResponse)
        let location = (http.value(forHTTPHeaderField: "Location")).flatMap(URL.init(string:))
        return (http.statusCode, location, String(bytes: data, encoding: .utf8) ?? "")
    }

    private static func hiddenFields(in html: String) -> [String: String] {
        let pattern = #/<input type="hidden" name="([^"]*)" value="([^"]*)">/#
        var fields: [String: String] = [:]
        for match in html.matches(of: pattern) {
            fields[unescape(String(match.1))] = unescape(String(match.2))
        }
        return fields
    }

    private static func unescape(_ text: String) -> String {
        text.replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}

/// The real `AuthenticationService`, the real SDK, and a server that is not.
///
/// What these prove is that the mock server is good enough to stand in for a real one from the
/// first keystroke to a `UserSession` — which is the whole of what it is for. If one of these
/// starts failing after an SDK update, the SDK has started asking for something the mock does not
/// answer, and `server.unanswered` names it.
@MainActor
@Suite("Sign-in mock server", .serialized)
struct SignInMockServerTests {
    private func service() -> AuthenticationService {
        AuthenticationService(environment: AppEnvironment(storage: .scratch(.temporaryDirectory.appending(component: "IskraMockTests-\(UUID())"))),
                              sessionStore: SessionStore(secrets: InMemorySecrets()))
    }

    @Test("discovery reports every way in that the server was told to offer")
    func discoversOptions() async throws {
        let server = SignInMockServer()
        let (proxy, address) = try await server.start()
        defer { Task { await proxy.stop() } }

        let options = try await service().startSignIn(homeserverAddress: address)

        #expect(options.supportsPassword)
        #expect(options.supportsOAuth)
        #expect(options.supportsRegistration)
    }

    @Test("a password-only server offers no registration")
    func passwordOnly() async throws {
        let server = SignInMockServer(configuration: .init(offersOAuth: false, offersRegistration: false))
        let (proxy, address) = try await server.start()
        defer { Task { await proxy.stop() } }

        let options = try await service().startSignIn(homeserverAddress: address)

        #expect(options.supportsPassword)
        #expect(!options.canUseSingleSignOn)
        #expect(!options.supportsRegistration)
    }

    @Test("the right password ends in a signed-in session")
    func signsInWithPassword() async throws {
        let server = SignInMockServer()
        let (proxy, address) = try await server.start()
        defer { Task { await proxy.stop() } }

        let authentication = service()
        _ = try await authentication.startSignIn(homeserverAddress: address)
        let session = try await authentication.signIn(username: "alice", password: "password")

        #expect(session.userID == "@alice:iskra.test")
    }

    @Test("the wrong password is refused")
    func refusesWrongPassword() async throws {
        let server = SignInMockServer()
        let (proxy, address) = try await server.start()
        defer { Task { await proxy.stop() } }

        let authentication = service()
        _ = try await authentication.startSignIn(homeserverAddress: address)

        await #expect(throws: AuthenticationError.self) {
            _ = try await authentication.signIn(username: "alice", password: "wrong")
        }
    }

    @Test("registering through the browser makes the account and signs into it")
    func registersThroughBrowser() async throws {
        let server = SignInMockServer()
        let (proxy, address) = try await server.start()
        defer { Task { await proxy.stop() } }

        let authentication = service()
        _ = try await authentication.startSignIn(homeserverAddress: address)
        let page = try await authentication.registrationURL()

        let answer = try await Browser().submit(page, username: "boris", password: "secret")
        let callback = try #require(answer.location, "the page should have redirected: \(answer.body)")
        #expect(callback.scheme == "moscow.swag.iskra")

        let session = try await authentication.completeSingleSignOn(callbackURL: callback)

        #expect(session.userID == "@boris:iskra.test")
        #expect(server.accounts["boris"] == "secret")
    }

    @Test("registering a name that is taken stays on the page and says so")
    func registrationRefusesTakenName() async throws {
        let server = SignInMockServer()
        let (proxy, address) = try await server.start()
        defer { Task { await proxy.stop() } }

        let authentication = service()
        _ = try await authentication.startSignIn(homeserverAddress: address)
        let page = try await authentication.registrationURL()

        let answer = try await Browser().submit(page, username: "alice", password: "anything")

        #expect(answer.status == 200)
        #expect(answer.location == nil)
        #expect(answer.body.contains("занято"))
    }

    @Test("signing in through the browser works as well as by password")
    func signsInThroughBrowser() async throws {
        let server = SignInMockServer()
        let (proxy, address) = try await server.start()
        defer { Task { await proxy.stop() } }

        let authentication = service()
        _ = try await authentication.startSignIn(homeserverAddress: address)
        let page = try await authentication.singleSignOnURL()

        let answer = try await Browser().submit(page, username: "alice", password: "password")
        let callback = try #require(answer.location)
        let session = try await authentication.completeSingleSignOn(callbackURL: callback)

        #expect(session.userID == "@alice:iskra.test")
    }

    @Test("legacy SSO comes back with a login token and finishes the same way")
    func legacySingleSignOn() async throws {
        let server = SignInMockServer(configuration: .init(offersPassword: false, offersLegacySSO: true,
                                                         offersOAuth: false, offersRegistration: false))
        let (proxy, address) = try await server.start()
        defer { Task { await proxy.stop() } }

        let authentication = service()
        let options = try await authentication.startSignIn(homeserverAddress: address)
        #expect(options.supportsLegacySSO)
        #expect(!options.supportsOAuth)

        let page = try await authentication.singleSignOnURL()
        let answer = try await Browser().submit(page, username: "alice", password: "password")
        let callback = try #require(answer.location, "the page should have redirected: \(answer.body)")
        let session = try await authentication.completeSingleSignOn(callbackURL: callback)

        #expect(session.userID == "@alice:iskra.test")
    }
}
