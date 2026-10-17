import Foundation
import Observation
import IskraCore

/// Drives the sign-in screen.
///
/// Matrix's sign-in story is genuinely complicated — three auth methods, servers
/// discovered from a domain name, a browser round-trip — and none of that is the
/// user's problem. This model absorbs it and exposes three states: the address, the door
/// ("sign in" or "create an account", on the server that was just found) and, only where the door
/// alone was not enough, "here's how you get in".
@MainActor
@Observable
public final class SignInModel {
    public enum Step: Equatable {
        /// The opening screen: the server's address, and "Next".
        case enteringAddress
        /// The server answered: the two buttons, "sign in" and "create an account", on the same
        /// screen, in place of the field.
        case found(SignInOptions)
        /// The form, where the door alone was not enough — a server with nothing but a password,
        /// or a browser closed half way.
        case ready(SignInOptions)
    }

    /// The server, as typed or as picked from `PublicServer.all`.
    ///
    /// It starts empty. It used to start on matrix.org, which quietly made one server's choice for
    /// everybody and put every new account in the same place; now the question is asked, and
    /// "Not sure which server to choose?" is right under it for the people who have no answer.
    public var address: String = ""

    /// What the visitor pressed — sign in, or make an account. Which button spins.
    public enum Intent: Equatable { case signIn, createAccount }
    public private(set) var pending: Intent?

    private var hasSignedIn = false
    public private(set) var step: Step = .enteringAddress
    public private(set) var isBusy = false
    /// Always a sentence, always about what the user should do next.
    public private(set) var problem: LocalizedStringResource?
    /// Whether the problem is one the bridge might get round: the server did not answer, and the
    /// bridge is off. A blocked server and a mistyped one fail alike from here — a block cuts the
    /// connection, and the SDK calls that "not found" — so the offer comes with both, and says it
    /// is about a block.
    public private(set) var canTryBridge = false

    public var username: String = ""
    public var password: String = ""

    private let authentication: AuthenticationService
    private let onSignedIn: @MainActor (UserSession) -> Void

    public init(authentication: AuthenticationService = AuthenticationService(),
                address: String = "",
                onSignedIn: @escaping @MainActor (UserSession) -> Void) {
        self.authentication = authentication
        self.address = address
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

    /// The options of the server that was found, on either of the two steps past the address.
    private var options: SignInOptions? {
        switch step {
        case .enteringAddress: nil
        case let .found(options), let .ready(options): options
        }
    }

    /// One of the two buttons that replace the field once the server is found.
    ///
    /// Signing in, on a server with a sign-in page of its own, goes straight to it — no second
    /// screen asking which way in. Only a server with nothing but a password gets a form, and a
    /// browser closed half way brings up the same quiet second screen, with the way back to the
    /// browser and the password beside it. Making an account goes to the server's page for it,
    /// and says so plainly where the server has none.
    ///
    /// The server is not looked up again: "Next" did that, and the attempt it started is still
    /// open — which is also why a browser closed half way leaves it open rather than cancelling
    /// it, so the next press goes straight back to the browser.
    public func begin(_ intent: Intent) async {
        guard !isBusy, let options else { return }
        pending = intent
        defer { pending = nil }

        switch intent {
        case .signIn:
            if options.canUseSingleSignOn {
                await continueWithSingleSignOn()
                if !hasSignedIn, problem == nil || options.supportsPassword {
                    step = .ready(options)
                }
            } else {
                step = .ready(options)
            }

        case .createAccount:
            guard options.supportsRegistration else {
                problem = Strings.SignIn.Problem.noRegistration
                return
            }
            await createAccount()
        }
    }

    /// "Next": looks up the address the user typed and works out how they can sign in.
    public func findServer() async {
        guard canContinue else { return }
        if let options = await lookUp() { step = .found(options) }
    }

    /// From the form back to the two buttons. The server is the same one, so the attempt stays.
    public func back() {
        guard let options else { return }
        step = .found(options)
        problem = nil
        username = ""
        password = ""
    }

    /// "Turn on the bridge and try again": the switch in Settings → Connection, flipped from here,
    /// and the same lookup again.
    ///
    /// It is the device's switch and not a one-off for this attempt — an account reached through
    /// the bridge has to keep being reached through it. `changed` is posted for the account that
    /// may be open under "Add account", which goes through the bridge from now on as well.
    public func tryThroughBridge() async {
        guard canTryBridge, !isBusy else { return }
        TunnelSettings.store.set(true, forKey: TunnelSettings.enabledKey)
        NotificationCenter.default.post(name: TunnelSettings.changed, object: nil)
        await findServer()
    }

    private func lookUp() async -> SignInOptions? {
        isBusy = true
        problem = nil
        canTryBridge = false
        defer { isBusy = false }

        do {
            return try await authentication.startSignIn(homeserverAddress: address.trimmingCharacters(in: .whitespaces))
        } catch AuthenticationError.homeserverNotFound {
            problem = Strings.SignIn.Problem.notFound
            canTryBridge = !TunnelSettings.isEnabled()
        } catch AuthenticationError.homeserverUnreachable {
            problem = Strings.SignIn.Problem.unreachable
            canTryBridge = !TunnelSettings.isEnabled()
        } catch AuthenticationError.noSupportedSignInMethod {
            problem = Strings.SignIn.Problem.unsupportedMethod
        } catch AuthenticationError.storageUnavailable {
            // Nothing to do with what they typed, so do not send them back to the
            // address field to hunt for a typo that isn't there.
            problem = Strings.SignIn.Problem.storageUnavailable
        } catch AuthenticationError.bridgeRefused(let refusal) {
            // The same reasoning: the address is fine, the bridge will not go there. The SDK would
            // have called it "not found" and sent them hunting for a typo.
            problem = Strings.Bridge.refusal(refusal)
        } catch AuthenticationError.bridgeUnavailable {
            problem = Strings.SignIn.Problem.bridgeUnavailable
        } catch {
            problem = Strings.SignIn.Problem.unreachable
            canTryBridge = !TunnelSettings.isEnabled()
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

    /// Back to the address, to change it. What was typed stays, to be corrected rather than
    /// typed again.
    public func startOver() async {
        await authentication.cancelSignIn()
        step = .enteringAddress
        problem = nil
        canTryBridge = false
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
