// Debug only: the demo is for looking at screens during development, and a release build carries
// none of it — no server to switch on, no flag to start it by. See CLAUDE.md, "The demo server".
#if DEBUG
import Foundation
import IskraCore

/// `Iskra --mock-signin`: the sign-in and registration screens, against a server inside the app.
///
/// For working on those screens without an account to burn, a network to depend on, or a real
/// homeserver's opinion about how many accounts one person may register in an afternoon. The server
/// is `SignInMockServer`; everything between the screen and it — `SignInModel`,
/// `AuthenticationService`, the SDK, the browser — is the real thing, and the flow ends in a real
/// session on an empty account.
///
/// Words after the flag pick what kind of server it is, and combine:
///
/// ```sh
/// Iskra --mock-signin                  # OIDC with registration, and a password form behind it
/// Iskra --mock-signin password         # password only: no browser, no "create account"
/// Iskra --mock-signin sso              # the old m.login.sso redirect, and nothing else
/// Iskra --mock-signin closed           # OIDC, but registration is not offered
/// Iskra --mock-signin slow             # any of the above, two seconds per request
/// ```
///
/// There is always an account `alice` with the password `password`; registration adds more, for as
/// long as the app runs.
///
/// **Nothing it does touches the real account on the device.** The session's store goes in a
/// scratch directory and its tokens in memory (`StorageMode.scratch`, `InMemorySecrets`), so the
/// next launch without the flag finds whoever was signed in before, exactly as they were — and
/// signing out of the mock account leaves the device's settings alone (see `AppSettings.forget`).
@MainActor
public enum MockSignIn {
    public static var isRequested: Bool {
        CommandLine.arguments.contains(flag)
    }

    /// The service every sign-in screen uses while the flag is on. One per launch, because the
    /// session it hands out keeps it, and signing out has to reach the same in-memory secrets that
    /// signing in wrote.
    public static let authentication = AuthenticationService(
        environment: AppEnvironment(storage: .scratch(scratch)),
        sessionStore: SessionStore(secrets: InMemorySecrets())
    )

    private static var running: (proxy: LocalHTTPProxy, address: String)?

    /// Brings the server up — once — and returns the address to type in. Nil if the listener would
    /// not start, in which case the sign-in screen opens empty and says nothing, rather than
    /// pointing at a port where nothing is listening.
    public static func start() async -> String? {
        if let running { return running.address }

        // Last launch's leftovers: a store for an account on a server that no longer exists.
        try? FileManager.default.removeItem(at: scratch)

        let server = SignInMockServer(configuration: configuration(from: CommandLine.arguments))
        do {
            let started = try await server.start()
            running = started
            print("Iskra --mock-signin: \(started.address) — alice / password")
            return started.address
        } catch {
            print("Iskra --mock-signin: could not start: \(error)")
            return nil
        }
    }

    static func configuration(from arguments: [String]) -> SignInMockServer.Configuration {
        let words = arguments.firstIndex(of: flag).map { Set(arguments[($0 + 1)...]) } ?? []
        var configuration = SignInMockServer.Configuration()

        if words.contains("password") {
            configuration.offersOAuth = false
            configuration.offersRegistration = false
        }
        if words.contains("sso") {
            configuration.offersPassword = false
            configuration.offersOAuth = false
            configuration.offersRegistration = false
            configuration.offersLegacySSO = true
        }
        if words.contains("closed") {
            configuration.offersRegistration = false
        }
        if words.contains("slow") {
            configuration.latency = .seconds(2)
        }
        return configuration
    }

    private static let flag = "--mock-signin"

    private static let scratch = URL.temporaryDirectory.appending(component: "IskraMockServer")
}
#else
import IskraCore

/// A release build has no server inside it — see the `#if DEBUG` above. What remains is the answer
/// every caller asks first: no, the flag is not on.
@MainActor
public enum MockSignIn {
    public static var isRequested: Bool { false }
    public static var authentication: AuthenticationService { AuthenticationService() }
    public static func start() async -> String? { nil }
}
#endif
