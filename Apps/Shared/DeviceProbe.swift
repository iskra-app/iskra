import Foundation
import IskraCore
import MatrixRustSDK

/// `Iskra --probe-devices` asks the one question that decides whether this app can ever
/// show you your other sessions.
///
/// The FFI has no `Client.devices()`. What it has is `Client.getUrl(url:)`, described as a
/// generic GET "through the SDK's internal HTTP client" — and the whole question is what
/// *internal* means there. If that client is the one the SDK makes authenticated requests
/// with, then `GET /_matrix/client/v3/devices` comes back with the device list and a
/// sessions screen is a morning's work. If it is the bare HTTP client the SDK also uses to
/// fetch a homeserver's `.well-known` — a request that carries no token, because it is made
/// before there is one — then it comes back `401 M_MISSING_TOKEN` and the screen cannot be
/// built at all without writing our own authenticated HTTP client on top of somebody else's
/// access token, which is not a thing to do to a token.
///
/// Reading the SDK says the second. This says so out loud, from a real signed-in session,
/// because "reading the SDK says" is how the timeline came to be fetched by drawing a
/// spinner.
///
/// Run it on a device or simulator that is already signed in — it restores the stored
/// session and makes exactly one request.
enum DeviceProbe {
    static var wasRequested: Bool {
        CommandLine.arguments.contains("--probe-devices")
    }

    static func runAndExit() -> Never {
        print("Iskra device-list probe")

        SDKLogging.start()

        Task {
            do {
                guard let client = try await AuthenticationService().restorePreviousSession() else {
                    print("  ❌ nobody is signed in on this device. Sign in first, then run this.")
                    exit(1)
                }

                // The trailing slash is not always there and not never there, and joining
                // the two halves without looking gets a 404 that reads exactly like a
                // homeserver refusing the endpoint.
                let base = client.homeserver().hasSuffix("/")
                    ? String(client.homeserver().dropLast())
                    : client.homeserver()
                let url = "\(base)/_matrix/client/v3/devices"
                print("  GET \(url)")

                // The interesting outcome is the *failure*, and it arrives as a thrown
                // `ClientError.Generic` whose `details` carry the response body — which is
                // where `M_MISSING_TOKEN` will be, if that is the answer.
                let data = try await client.getUrl(url: url)
                let body = String(data: data, encoding: .utf8) ?? "<\(data.count) bytes, not UTF-8>"

                // Deliberately printed. This is a list of the user's own device IDs on their
                // own console — and if it *does* come back, that fact is the finding.
                print("  ✅ answered: \(body.prefix(400))")
                print("     getUrl carries the access token → a sessions screen is possible.")
                exit(0)
            } catch {
                print("  ❌ refused: \(error)")
                print("     If that says M_MISSING_TOKEN, getUrl is unauthenticated and")
                print("     the device list cannot be reached through the FFI at all.")
                exit(1)
            }
        }

        dispatchMain()
    }
}
