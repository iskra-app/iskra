import Foundation
import Testing
@testable import IskraCore
@testable import IskraFeatures

/// The sign-in screen's model against `SignInMockServer` — the same object the buttons call, with
/// no network at all. The network-tagged `SignInModelTests` prove the same model against
/// matrix.org; these prove it against a server whose answers are known, which is what lets them
/// check the failures as well as the success.
@MainActor
@Suite("Sign-in against the mock server", .serialized)
struct MockSignInTests {
    private func authentication() -> AuthenticationService {
        AuthenticationService(environment: AppEnvironment(storage: .scratch(URL.temporaryDirectory.appending(component: "IskraMockTests-\(UUID())"))),
                              sessionStore: SessionStore(secrets: InMemorySecrets()))
    }

    @Test("finding the server leads to the way in")
    func findsServer() async throws {
        let server = SignInMockServer()
        let (proxy, address) = try await server.start()
        defer { Task { await proxy.stop() } }

        let model = SignInModel(authentication: authentication(), address: address) { _ in }
        await model.findServer()

        #expect(model.problem == nil)
        guard case let .ready(options) = model.step else {
            Issue.record("expected the sign-in step, got \(model.step)")
            return
        }
        #expect(options.supportsRegistration)
    }

    @Test("a password signs in and hands the session up")
    func passwordSignsIn() async throws {
        let server = SignInMockServer()
        let (proxy, address) = try await server.start()
        defer { Task { await proxy.stop() } }

        var signedIn: UserSession?
        let model = SignInModel(authentication: authentication(), address: address) { signedIn = $0 }
        await model.findServer()
        model.username = "alice"
        model.password = "password"
        await model.signInWithPassword()

        #expect(model.problem == nil)
        #expect(model.password.isEmpty)
        #expect(signedIn?.userID == "@alice:iskra.test")
    }

    @Test("a wrong password says so and keeps the user on the screen")
    func wrongPassword() async throws {
        let server = SignInMockServer()
        let (proxy, address) = try await server.start()
        defer { Task { await proxy.stop() } }

        let model = SignInModel(authentication: authentication(), address: address) { _ in
            Issue.record("a wrong password must not sign anybody in")
        }
        await model.findServer()
        model.username = "alice"
        model.password = "nope"
        await model.signInWithPassword()

        #expect(model.problem == Strings.SignIn.Problem.badCredentials)
        #expect(!model.isBusy)
    }

    @Test("a new account gets as far as its recovery code")
    func newAccountSetsUp() async throws {
        let server = SignInMockServer()
        let (proxy, address) = try await server.start()
        defer { Task { await proxy.stop() } }

        var signedIn: UserSession?
        let model = SignInModel(authentication: authentication(), address: address) { signedIn = $0 }
        await model.findServer()
        model.username = "alice"
        model.password = "password"
        await model.signInWithPassword()
        let session = try #require(signedIn)

        // What the root view does next: start the session, and ask where the account stands.
        try await session.start()
        let setup = RecoverySetupModel(session: session)
        await setup.begin()

        #expect(setup.step == .code, "the first-run screen should show a fresh recovery code")
        #expect(setup.code != nil)

        // And nothing along the way was met with a shrug. An SDK update that starts asking for
        // something new fails here, by name, rather than as a first-run screen that quietly gives up.
        let unanswered = server.unanswered.map { "\($0.method) \($0.target)" }
        #expect(unanswered.isEmpty, "the mock server had no answer for: \(unanswered)")
        await session.signOut()
    }

    @Test("the launch words pick the kind of server")
    func launchWords() {
        let plain = MockSignIn.configuration(from: ["Iskra", "--mock-signin"])
        #expect(plain.offersOAuth && plain.offersRegistration && plain.offersPassword)

        let password = MockSignIn.configuration(from: ["Iskra", "--mock-signin", "password"])
        #expect(!password.offersOAuth && !password.offersRegistration && password.offersPassword)

        let sso = MockSignIn.configuration(from: ["Iskra", "--mock-signin", "sso", "slow"])
        #expect(sso.offersLegacySSO && !sso.offersPassword && !sso.offersOAuth)
        #expect(sso.latency == .seconds(2))

        let closed = MockSignIn.configuration(from: ["Iskra", "--mock-signin", "closed"])
        #expect(closed.offersOAuth && !closed.offersRegistration)
    }
}
