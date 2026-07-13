import Foundation
import MatrixRustSDK

/// Whether this account's *other* sessions can be reached at all.
///
/// A diagnostic, not a feature — but it lives here rather than in the app shell because
/// answering it means holding a `Client`, knowing a Matrix endpoint, and reading an error
/// code out of a homeserver's response body. All three of those are `IskraCore`'s business
/// by the rule the whole project hangs on, and the app above is entitled to the verdict
/// without learning any of it. `Apps/Shared/DeviceProbe.swift` is a `print` and nothing
/// more.
///
/// The question itself: the FFI has no `Client.devices()`. What it has is `getUrl`, a GET
/// "through the SDK's internal HTTP client" — and everything turns on whether that client
/// carries the access token. It does not, and this is what says so out loud, from a real
/// session, rather than from a reading of the SDK.
public enum DeviceListProbe {
    public enum Verdict: Sendable {
        /// Nobody is signed in on this device, so there is nothing to ask about.
        case notSignedIn
        /// The endpoint answered. `getUrl` is authenticated after all, and a sessions screen
        /// is possible — the body is handed back so the caller can show what came.
        case answered(String)
        /// The homeserver refused for want of a token: `getUrl` is unauthenticated, and the
        /// device list is out of reach through the FFI.
        case unauthenticated
        /// It failed some other way, which is its own finding.
        case refused(String)
    }

    public static func run() async -> Verdict {
        guard let client = try? await AuthenticationService().restorePreviousSession() else {
            return .notSignedIn
        }

        // The homeserver may or may not come with a trailing slash, and joining the halves
        // without looking gets a 404 that reads exactly like a homeserver refusing the
        // endpoint — which is the wrong finding, arrived at convincingly.
        guard let url = URL(string: client.homeserver())?
            .appending(path: "_matrix/client/v3/devices") else {
            return .refused("the homeserver is not a URL: \(client.homeserver())")
        }

        do {
            let data = try await client.getUrl(url: url.absoluteString)
            return .answered(String(data: data, encoding: .utf8) ?? "\(data.count) bytes, not UTF-8")
        } catch {
            // The refusal arrives as a `ClientError.Generic` whose details carry the response
            // body, which is where the error code is.
            let described = String(describing: error)
            return described.contains("M_MISSING_TOKEN") ? .unauthenticated : .refused(described)
        }
    }
}
