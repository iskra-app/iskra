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

    @Test("\"Next\" finds the server and offers the two buttons")
    func findsServer() async throws {
        let server = SignInMockServer()
        let (proxy, address) = try await server.start()
        defer { Task { await proxy.stop() } }

        let model = SignInModel(authentication: authentication(), address: address) { _ in }
        await model.findServer()

        #expect(model.problem == nil)
        guard case let .found(options) = model.step else {
            Issue.record("expected the server to be found, got \(model.step)")
            return
        }
        #expect(options.supportsRegistration)
    }

    @Test("\"Sign in\" on a password-only server goes to the form, and back returns to the buttons")
    func signInOpensFormAndBack() async throws {
        let server = SignInMockServer(configuration: .init(offersOAuth: false, offersRegistration: false))
        let (proxy, address) = try await server.start()
        defer { Task { await proxy.stop() } }

        let model = SignInModel(authentication: authentication(), address: address) { _ in }
        await model.findServer()
        await model.begin(.signIn)
        guard case .ready = model.step else {
            Issue.record("expected the form, got \(model.step)")
            return
        }

        model.back()
        guard case .found = model.step else {
            Issue.record("expected the two buttons again, got \(model.step)")
            return
        }

        // The attempt "Next" started is still the one in use: the form signs in without a second lookup.
        await model.begin(.signIn)
        model.username = "alice"
        model.password = "password"
        await model.signInWithPassword()
        #expect(model.problem == nil)
    }

    @Test("\"Create account\" on a server that cannot make one says so and stays")
    func noRegistrationStays() async throws {
        let server = SignInMockServer(configuration: .init(offersRegistration: false))
        let (proxy, address) = try await server.start()
        defer { Task { await proxy.stop() } }

        let model = SignInModel(authentication: authentication(), address: address) { _ in }
        await model.findServer()
        await model.begin(.createAccount)

        #expect(model.problem == Strings.SignIn.Problem.noRegistration)
        guard case .found = model.step else {
            Issue.record("expected to stay on the two buttons, got \(model.step)")
            return
        }
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

    // MARK: - More than one account

    /// Signs in with a password through the model, the way the sheet does.
    private func signIn(_ username: String,
                        with authentication: AuthenticationService,
                        at address: String) async -> (UserSession?, SignInModel) {
        var signedIn: UserSession?
        let model = SignInModel(authentication: authentication, address: address) { signedIn = $0 }
        await model.findServer()
        model.username = username
        model.password = "password"
        await model.signInWithPassword()
        return (signedIn, model)
    }

    @Test("a second account is added beside the first, and the first stays signed in")
    func twoAccounts() async throws {
        let server = SignInMockServer(configuration: .init(accounts: ["alice": "password", "bob": "password"]))
        let (proxy, address) = try await server.start()
        defer { Task { await proxy.stop() } }

        let authentication = authentication()
        let (alice, _) = await signIn("alice", with: authentication, at: address)
        let aliceSession = try #require(alice)
        await authentication.sessionOpened(aliceSession.sessionID)

        let (bob, _) = await signIn("bob", with: authentication, at: address)
        let bobSession = try #require(bob)

        #expect(authentication.accounts().map(\.userID) == ["@alice:iskra.test", "@bob:iskra.test"])
        #expect(authentication.activeAccountID() == bobSession.sessionID)
        #expect(aliceSession.sessionID != bobSession.sessionID)

        // Signing out of one leaves the other exactly where it was.
        await bobSession.signOut()
        #expect(authentication.accounts().map(\.userID) == ["@alice:iskra.test"])
        #expect(authentication.activeAccountID() == aliceSession.sessionID)
    }

    @Test("adding the account that is open is refused, and says why")
    func theOpenAccountCannotBeAddedAgain() async throws {
        let server = SignInMockServer()
        let (proxy, address) = try await server.start()
        defer { Task { await proxy.stop() } }

        let authentication = authentication()
        let (alice, _) = await signIn("alice", with: authentication, at: address)
        await authentication.sessionOpened(try #require(alice).sessionID)

        let (again, model) = await signIn("alice", with: authentication, at: address)

        #expect(again == nil)
        #expect(model.problem == Strings.SignIn.Problem.alreadySignedIn)
        #expect(model.step == .enteringAddress)
        #expect(authentication.accounts().count == 1)
    }

    /// An account that could not be opened — its session ended, its store would not decrypt — is
    /// mended by signing in again, and the broken record makes way rather than refusing it.
    @Test("signing in again to an account that is not open replaces its old record")
    func aClosedAccountIsReplaced() async throws {
        let server = SignInMockServer()
        let (proxy, address) = try await server.start()
        defer { Task { await proxy.stop() } }

        let authentication = authentication()
        let (first, _) = await signIn("alice", with: authentication, at: address)
        let old = try #require(first).sessionID

        let (second, _) = await signIn("alice", with: authentication, at: address)
        let new = try #require(second).sessionID

        #expect(old != new)
        #expect(authentication.accounts().map(\.sessionID) == [new])
    }
}
