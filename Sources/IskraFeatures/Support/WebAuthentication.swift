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
        // Held for the life of the call, and *read* at the end of it, which is the whole point.
        //
        // `ASWebAuthenticationSession` cancels itself the moment it is deallocated, and the only
        // other reference to it is the one the system holds while the browser is up — so a session
        // owned by nothing on our side is a browser that closes as fast as it opens. It used to live
        // in a property on `SignInModel`; when this moved out into a function, it became a local
        // that was assigned and never looked at again, which is a variable the compiler is entitled
        // to release immediately. It said so, in a warning, and the warning was right: signing in
        // with OAuth stopped working.
        //
        // The `defer` is not tidiness. It is the read that keeps the box — and the session inside it
        // — alive across the suspension.
        let holder = Holder()
        defer { holder.session = nil }

        return try await withCheckedThrowingContinuation { continuation in
            // `@Sendable` is load-bearing, not a formality. Formed inside a `@MainActor` function, a
            // non-`Sendable` completion handler inherits main-actor isolation — and on macOS 26
            // AuthenticationServices delivers this callback on a background XPC reply queue, not the
            // main thread. The runtime's executor-identity check at the top of a main-actor closure
            // then traps (`SIGTRAP`, `dispatch_assert_queue_fail`) the instant sign-in completes.
            // `@Sendable` makes the closure non-isolated so it may run on whatever queue calls it;
            // its body only resumes the continuation, which is safe from any thread.
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { @Sendable callbackURL, error in
                if let callbackURL {
                    continuation.resume(returning: callbackURL)
                } else if let error = error as? ASWebAuthenticationSessionError,
                          error.code == .canceledLogin {
                    continuation.resume(throwing: CancellationError())
                } else if let error {
                    continuation.resume(throwing: Failure.browser(code: (error as NSError).code))
                } else {
                    continuation.resume(throwing: Failure.noCallback)
                }
            }

            session.presentationContextProvider = Anchor.shared
            // The user may already be signed in to their provider in Safari; letting that session be
            // reused is the difference between one tap and a password.
            session.prefersEphemeralWebBrowserSession = false

            holder.session = session
            session.start()
        }
    }

    /// Somewhere for the session to live that is not a local the optimiser can throw away.
    @MainActor
    private final class Holder {
        var session: ASWebAuthenticationSession?
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
        /// The browser closed with neither a callback nor an error, which should not happen and
        /// therefore is exactly the thing worth naming.
        case noCallback
        /// The browser itself refused. The code is carried so the log can say *which* refusal —
        /// the URL is not, because a callback URL carries the authorization code and is worth as
        /// much as the token it buys.
        case browser(code: Int)
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
