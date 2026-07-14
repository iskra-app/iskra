import Foundation
import IskraCore

/// `Iskra --probe-devices` asks the one question that decides whether this app can ever
/// show you your other sessions: does `Client.getUrl` carry the access token?
///
/// The asking is `DeviceListProbe`, in `IskraCore`, which is where the `Client` and the
/// Matrix endpoint belong. This is the printing — the same division as `SignInProbe`, which
/// drives `AuthenticationService` and speaks only in `IskraCore`'s own vocabulary.
///
/// Run it on a device or simulator that is already signed in; it restores the stored session
/// and makes exactly one request.
enum DeviceProbe {
    static var wasRequested: Bool {
        CommandLine.arguments.contains("--probe-devices")
    }

    static func runAndExit() -> Never {
        print("Iskra device-list probe")

        SDKLogging.start()

        Task {
            // Question one, and the answer is no. Kept because a negative that has been *checked* is
            // worth more than a negative that has been reasoned about.
            print("\n  can this app fetch the device list itself?")

            switch await DeviceListProbe.listEndpoint() {
            case .notSignedIn:
                print("  ❌ nobody is signed in on this device. Sign in first, then run this.")
                exit(1)

            case let .answered(body):
                // Deliberately printed. These are the user's own device IDs on their own
                // console — and if the list *does* come back, that fact is the finding.
                print("  ✅ answered: \(body.prefix(400))")
                print("     getUrl carries the access token → a sessions screen is possible.")

            case .unauthenticated:
                print("  ❌ 401 M_MISSING_TOKEN — getUrl goes out on the SDK's bare HTTP client.")
                print("     Expected. And on a server running MAS the delete endpoint is 404 anyway.")

            case let .refused(reason):
                print("  ❌ refused: \(reason)")
            }

            // Question two, and this is the one the settings row hangs on.
            print("\n  can this app send the user somewhere that can?")

            switch await DeviceListProbe.managementPage() {
            case .notSignedIn:
                print("  ❌ nobody is signed in on this device.")
                exit(1)

            case let .at(address):
                print("  ✅ \(address)")
                print("     → the “My devices” row appears in settings and opens this.")
                exit(0)

            case .none:
                print("  ⚠️  accountUrl returned nothing: this session did not come through OAuth,")
                print("     so the server has no account page to point at. The row is not drawn —")
                print("     which is correct, and is not the same thing as a bug.")
                exit(1)

            case let .refused(reason):
                print("  ❌ refused: \(reason)")
                exit(1)
            }
        }

        dispatchMain()
    }
}
