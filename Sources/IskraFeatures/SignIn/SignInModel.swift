import Foundation
import Observation
import AuthenticationServices
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
    private var webAuthSession: ASWebAuthenticationSession?

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
        isBusy = true
        problem = nil

        do {
            let url = try await authentication.singleSignOnURL()
            let callback = try await presentWebAuthentication(url: url)
            let session = try await authentication.completeSingleSignOn(callbackURL: callback)
            await finish(with: session)
        } catch is CancellationError {
            // The user closed the browser. Not an error, and not worth a message.
            isBusy = false
        } catch {
            isBusy = false
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

    /// Bridges `ASWebAuthenticationSession`'s callback API into async/await.
    ///
    /// The callback URL carries the authorization code, so it is a secret: it is
    /// passed straight to the SDK and never logged.
    private func presentWebAuthentication(url: URL) async throws -> URL {
        let scheme = URL(string: AppEnvironment.default.oauthRedirectURI)?.scheme

        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme) { callbackURL, error in
                if let callbackURL {
                    continuation.resume(returning: callbackURL)
                } else if let error = error as? ASWebAuthenticationSessionError,
                          error.code == .canceledLogin {
                    continuation.resume(throwing: CancellationError())
                } else {
                    continuation.resume(throwing: error ?? AuthenticationError.invalidCallbackURL)
                }
            }

            session.presentationContextProvider = WebAuthenticationAnchor.shared
            // The user may already be signed in to their provider in Safari; letting
            // that session be reused is the difference between one tap and a password.
            session.prefersEphemeralWebBrowserSession = false

            self.webAuthSession = session
            session.start()
        }
    }
}

/// `ASWebAuthenticationSession` needs somewhere to put its browser.
private final class WebAuthenticationAnchor: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = WebAuthenticationAnchor()

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        #if os(macOS)
        NSApplication.shared.keyWindow ?? ASPresentationAnchor()
        #else
        let scene = UIApplication.shared.connectedScenes.first { $0.activationState == .foregroundActive }
        return (scene as? UIWindowScene)?.keyWindow ?? ASPresentationAnchor()
        #endif
    }
}

#if os(macOS)
import AppKit
#else
import UIKit
#endif
