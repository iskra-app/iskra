import Foundation
import AuthenticationServices

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Sending the user to a page on their server, and waiting for them to come back.
///
/// It used to live inside `SignInModel`, privately, because signing in was the only thing that
/// needed a browser. Starting over needs one too — throwing an account's encryption away is a thing
/// most servers want to watch the user approve on their own page — and the two wants are the same
/// want, so it is one function now rather than two that drift.
///
/// `ASWebAuthenticationSession` and not a plain `openURL`, and the difference is not cosmetic: this
/// is the only way the app is handed the callback URL back, and it is the only browser that shares
/// its cookies with Safari — which is what spares somebody who is already signed in to their server
/// from signing in to it a second time to approve something.
///
/// **Nothing here is logged.** A callback URL carries the authorization code, and is worth exactly
/// as much as the token it buys.
enum WebAuthentication {
    /// Opens `url` and resolves with the callback the server redirects to.
    ///
    /// Throws `CancellationError` when the user simply closes the browser, which is not a failure and
    /// should not be reported as one.
    @MainActor
    static func run(url: URL, callbackScheme: String?) async throws -> URL {
        // Held for the life of the call: `ASWebAuthenticationSession` cancels itself when it is
        // deallocated, and a session that is only referenced by the continuation is a session that
        // closes the browser the instant it opens.
        var session: ASWebAuthenticationSession?

        return try await withCheckedThrowingContinuation { continuation in
            let started = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { callbackURL, error in
                if let callbackURL {
                    continuation.resume(returning: callbackURL)
                } else if let error = error as? ASWebAuthenticationSessionError,
                          error.code == .canceledLogin {
                    continuation.resume(throwing: CancellationError())
                } else {
                    continuation.resume(throwing: error ?? Failure.noCallback)
                }
            }

            started.presentationContextProvider = Anchor.shared
            // The user may already be signed in to their provider in Safari; letting that session be
            // reused is the difference between one tap and a password.
            started.prefersEphemeralWebBrowserSession = false

            session = started
            started.start()
        }
    }

    /// Opens `url` and waits only for the browser to be *closed*, with no callback expected.
    ///
    /// This is what approving an identity reset looks like: the server's page finishes, and the only
    /// signal we get is the user dismissing it. `run(url:callbackScheme:)` with a scheme nobody will
    /// ever redirect to would sit there forever, so the cancellation *is* the answer, and it is
    /// returned rather than thrown.
    @MainActor
    static func approve(url: URL) async {
        // A scheme that cannot match anything the server will redirect to: we are not waiting for a
        // redirect, we are waiting for a person to finish reading a page and close it.
        _ = try? await run(url: url, callbackScheme: nil)
    }

    enum Failure: Error {
        case noCallback
    }

    /// `ASWebAuthenticationSession` needs somewhere to put its browser.
    private final class Anchor: NSObject, ASWebAuthenticationPresentationContextProviding {
        static let shared = Anchor()

        func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
            #if os(macOS)
            NSApplication.shared.keyWindow ?? ASPresentationAnchor()
            #else
            let scene = UIApplication.shared.connectedScenes.first { $0.activationState == .foregroundActive }
            return (scene as? UIWindowScene)?.keyWindow ?? ASPresentationAnchor()
            #endif
        }
    }
}
