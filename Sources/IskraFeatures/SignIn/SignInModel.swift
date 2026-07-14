import Foundation
import Observation
import IskraCore

/// Drives the sign-in screen.
///
/// Matrix's sign-in story is genuinely complicated — three auth methods, servers
/// discovered from a domain name, a browser round-trip — and none of that is the
/// user's problem. This model absorbs it and exposes two states: "type your address"
/// and "here's how you get in".
@MainActor
@Observable
public final class SignInModel {
    public enum Step: Equatable {
        case enteringAddress
        /// The server was found and told us how it lets people in.
        case ready(SignInOptions)
    }

    public var address: String = ""
    public private(set) var step: Step = .enteringAddress
    public private(set) var isBusy = false
    /// Always a sentence, always about what the user should do next.
    public private(set) var problem: LocalizedStringResource?

    public var username: String = ""
    public var password: String = ""

    private let authentication: AuthenticationService
    private let onSignedIn: @MainActor (UserSession) -> Void

    public init(authentication: AuthenticationService = AuthenticationService(),
                onSignedIn: @escaping @MainActor (UserSession) -> Void) {
        self.authentication = authentication
        self.onSignedIn = onSignedIn
    }

    public var canContinue: Bool {
        !address.trimmingCharacters(in: .whitespaces).isEmpty && !isBusy
    }

    /// Looks up the address the user typed and works out how they can sign in.
    public func findServer() async {
        isBusy = true
        problem = nil
        defer { isBusy = false }

        do {
            let options = try await authentication.startSignIn(homeserverAddress: address.trimmingCharacters(in: .whitespaces))
            step = .ready(options)
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
        } catch {
            isBusy = false
            password = ""
            problem = Strings.SignIn.Problem.badCredentials
        }
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
        onSignedIn(session)
    }

}
