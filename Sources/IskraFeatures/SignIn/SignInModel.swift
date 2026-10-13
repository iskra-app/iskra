import Foundation
import Observation
import IskraCore

/// Drives the sign-in screen.
///
/// Matrix's sign-in story is genuinely complicated — three auth methods, servers
/// discovered from a domain name, a browser round-trip — and none of that is the
/// user's problem. This model absorbs it and exposes two states: the door ("sign in" or
/// "create an account", on a server already filled in) and, only where the door alone was not
/// enough, "here's how you get in".
@MainActor
@Observable
public final class SignInModel {
    public enum Step: Equatable {
        /// The opening screen: the two buttons, and the server they will go to.
        case enteringAddress
        /// The server was found and told us how it lets people in.
        case ready(SignInOptions)
    }

    /// The server, filled in before anybody is asked: matrix.org, where most people's accounts
    /// are and where a new one is made. It is shown as one quiet line with "Change" beside it, so
    /// the person who was given an address can type it and nobody else has to think about it.
    public var address: String = ""

    /// What the visitor pressed — sign in, or make an account. Which button spins.
    public enum Intent: Equatable { case signIn, createAccount }
    public private(set) var pending: Intent?

    /// The server matrix.org, as the opening screen offers it.
    public static let defaultAddress = "matrix.org"

    private var hasSignedIn = false
    public private(set) var step: Step = .enteringAddress
    public private(set) var isBusy = false
    /// Always a sentence, always about what the user should do next.
    public private(set) var problem: LocalizedStringResource?

    public var username: String = ""
    public var password: String = ""

    private let authentication: AuthenticationService
    private let onSignedIn: @MainActor (UserSession) -> Void

    public init(authentication: AuthenticationService = AuthenticationService(),
                address: String = "",
                onSignedIn: @escaping @MainActor (UserSession) -> Void) {
        self.authentication = authentication
        self.address = address.isEmpty ? Self.defaultAddress : address
        self.onSignedIn = onSignedIn
    }

    public var canContinue: Bool {
        !address.trimmingCharacters(in: .whitespaces).isEmpty && !isBusy
    }

    /// The server's name as the screen shows it — what was typed, without a scheme or a slash.
    public var serverName: String {
        var name = address.trimmingCharacters(in: .whitespaces)
        for prefix in ["https://", "http://"] where name.lowercased().hasPrefix(prefix) {
            name.removeFirst(prefix.count)
        }
        while name.hasSuffix("/") { name.removeLast() }
        return name
    }

    /// One of the two buttons on the opening screen.
    ///
    /// Signing in, on a server with a sign-in page of its own, goes straight to it — no second
    /// screen asking which way in. Only a server with nothing but a password gets a form, and a
    /// browser closed half way brings up the same quiet second screen, with the way back to the
    /// browser and the password beside it. Making an account goes to the server's page for it,
    /// and says so plainly where the server has none.
    public func begin(_ intent: Intent) async {
        guard !isBusy else { return }
        pending = intent
        defer { pending = nil }

        if case .ready = step {
            await authentication.cancelSignIn()
            step = .enteringAddress
        }
        guard let options = await lookUp() else { return }

        switch intent {
        case .signIn:
            if options.canUseSingleSignOn {
                await continueWithSingleSignOn()
                if !hasSignedIn {
                    if problem == nil || options.supportsPassword {
                        step = .ready(options)
                    } else {
                        await authentication.cancelSignIn()
                    }
                }
            } else {
                step = .ready(options)
            }

        case .createAccount:
            guard options.supportsRegistration else {
                await authentication.cancelSignIn()
                problem = Strings.SignIn.Problem.noRegistration
                return
            }
            await createAccount()
            if !hasSignedIn { await authentication.cancelSignIn() }
        }
    }

    /// Looks up the address the user typed and works out how they can sign in.
    public func findServer() async {
        if let options = await lookUp() { step = .ready(options) }
    }

    private func lookUp() async -> SignInOptions? {
        isBusy = true
        problem = nil
        defer { isBusy = false }

        do {
            return try await authentication.startSignIn(homeserverAddress: address.trimmingCharacters(in: .whitespaces))
        } catch AuthenticationError.homeserverNotFound {
            problem = Strings.SignIn.Problem.notFound
        } catch AuthenticationError.homeserverUnreachable {
            problem = Strings.SignIn.Problem.unreachable
        } catch AuthenticationError.noSupportedSignInMethod {
            problem = Strings.SignIn.Problem.unsupportedMethod
        } catch AuthenticationError.storageUnavailable {
            // Nothing to do with what they typed, so do not send them back to the
            // address field to hunt for a typo that isn't there.
            problem = Strings.SignIn.Problem.storageUnavailable
        } catch {
            problem = Strings.SignIn.Problem.unreachable
        }
        return nil
    }

    /// Opens the browser for single sign-on and waits for it to come back.
    public func continueWithSingleSignOn() async {
        await inBrowser { try await self.authentication.singleSignOnURL() }
    }

    /// Opens the browser to *make* an account rather than sign in to one.
    ///
    /// The same trip, and the same way home: the server redirects to the same callback, and
    /// `completeSingleSignOn` finishes it without caring which of the two happened. Past this point
    /// a brand-new account and a ten-year-old one are the same thing, which is why there is no
    /// second completion path.
    public func createAccount() async {
        await inBrowser { try await self.authentication.registrationURL() }
    }

    /// The browser round-trip that signing in and registering have in common.
    ///
    /// Every failure here used to arrive as the same sentence — "that sign-in didn't complete" — and
    /// nothing was written down, so a browser that closed itself the instant it opened looked exactly
    /// like a server that refused the code. It was in fact the first of those, for weeks, and the
    /// screen had no way to say so. The three steps are told apart now, and each says which one it
    /// was in the log. The *user* still gets one sentence, because there is only one thing they can
    /// do about any of them; the developer gets three.
    private func inBrowser(_ address: @escaping () async throws -> URL) async {
        isBusy = true
        problem = nil
        defer { isBusy = false }

        let url: URL
        do {
            url = try await address()
        } catch {
            Log.session.error("could not work out where to send the browser: \(Log.describe(error), privacy: .public)")
            problem = Strings.SignIn.Problem.ssoIncomplete
            return
        }

        let callback: URL
        do {
            let scheme = URL(string: AppEnvironment.default.oauthRedirectURI)?.scheme
            callback = try await WebAuthentication.run(url: url, callbackScheme: scheme)
        } catch is CancellationError {
            // The user closed the browser. Not an error, and not worth a message.
            return
        } catch {
            // The error, not the URL: a callback URL carries the authorization code.
            Log.session.error("the browser did not come back: \(Log.describe(error), privacy: .public)")
            problem = Strings.SignIn.Problem.ssoIncomplete
            return
        }

        do {
            let session = try await authentication.completeSingleSignOn(callbackURL: callback)
            await finish(with: session)
        } catch AuthenticationError.alreadySignedIn {
            alreadyOnTheDevice()
        } catch {
            Log.session.error("the server would not finish the sign-in: \(Log.describe(error), privacy: .public)")
            problem = Strings.SignIn.Problem.ssoIncomplete
        }
    }

    public func signInWithPassword() async {
        isBusy = true
        problem = nil

        do {
            let session = try await authentication.signIn(username: username, password: password)
            // The password has done its job; do not keep it in memory a moment longer.
            password = ""
            await finish(with: session)
        } catch AuthenticationError.alreadySignedIn {
            isBusy = false
            password = ""
            alreadyOnTheDevice()
        } catch {
            isBusy = false
            password = ""
            problem = Strings.SignIn.Problem.badCredentials
        }
    }

    /// Signed in to somebody who was already here. The attempt is gone — the service logged the
    /// new device out again — so the screen goes back to the address, saying why.
    private func alreadyOnTheDevice() {
        step = .enteringAddress
        username = ""
        password = ""
        problem = Strings.SignIn.Problem.alreadySignedIn
    }

    public func startOver() async {
        await authentication.cancelSignIn()
        step = .enteringAddress
        problem = nil
        username = ""
        password = ""
    }

    /// Signed in. The screen above is handed the session and takes the app into it.
    ///
    /// It used to be handed a `Client` — the SDK's own type — and build the session itself, which
    /// is why this file used to `import MatrixRustSDK` for exactly one word. The sign-in screen has
    /// no business naming a Matrix type, and now it does not: `AuthenticationService` hands back a
    /// `UserSession` and the client never leaves `IskraCore`.
    private func finish(with session: UserSession) async {
        isBusy = false
        hasSignedIn = true
        onSignedIn(session)
    }
}
