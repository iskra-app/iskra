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
/// The original question was: the FFI has no `Client.devices()`, but it has `getUrl`, a GET
/// "through the SDK's internal HTTP client" — does that client carry the access token? It does not,
/// and `listEndpoint()` still says so out loud, from a real session, rather than from a reading of
/// the SDK.
///
/// That answer was right and the conclusion drawn from it — "no device management is possible" — was
/// wrong, which is the more useful thing this file now records. `getUrl` was simply the wrong call.
/// `Client.accountUrl(action:)` builds the address of the server's own device page out of cached
/// OAuth metadata, and hands it over with the session the user already has. So there are two
/// questions here now, and `managementPage()` is the one that decides whether the row in settings
/// appears — which is why it is worth being able to ask it from a real signed-in device instead of
/// staring at a screen where a row is missing and guessing why.
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

    /// Where the user manages their devices — the question the settings row actually asks.
    public enum Page: Sendable {
        case notSignedIn
        /// The address of the server's device page. The row appears, and leads here.
        case at(String)
        /// The SDK has no such address: this session was not obtained through OAuth, so there is no
        /// account-management page to point at. The row is not drawn, and that is correct — but it is
        /// worth being able to tell this apart from a bug, which is the whole point of asking.
        case none
        case refused(String)
    }

    /// Can we reach the device list ourselves? (No. Kept because the negative is the finding.)
    public static func listEndpoint() async -> Verdict {
        guard let client = try? await AuthenticationService().restoreClient() else {
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

    /// Can we at least send the user somewhere that can? (Yes, on an OAuth session.)
    public static func managementPage() async -> Page {
        guard let client = try? await AuthenticationService().restoreClient() else {
            return .notSignedIn
        }

        do {
            guard let address = try await client.accountUrl(action: .devicesList) else { return .none }
            return .at(address)
        } catch {
            return .refused(String(describing: error))
        }
    }
}
