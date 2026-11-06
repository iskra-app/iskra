import Foundation
import IskraCore
import UserNotifications

/// `Iskra --probe-push` answers "notifications do not arrive" with which of the four it is: no
/// pusher on the server, a pusher pointing somewhere else, a gateway that does not answer, or a
/// token APNs refuses.
///
/// The asking is `PusherProbe`, in `IskraCore`; this is the printing, as with `DeviceProbe`. Run
/// it on the device that does not get notifications, signed in — `./device.sh --here --
/// --probe-push`. It sends that device one real push, which arrives as the plain fallback.
enum PushProbe {
    static var wasRequested: Bool {
        CommandLine.arguments.contains("--probe-push")
    }

    static func runAndExit() -> Never {
        print("Iskra push probe")
        print("  this build registers as \(PusherProbe.expectedAppID) → \(PusherProbe.expectedGateway ?? "nowhere")")

        SDKLogging.start()

        Task {
            print("\n  what pushers does the homeserver hold for this account?")

            let pushers: [PusherProbe.Pusher]
            switch await PusherProbe.list() {
            case .notSignedIn:
                print("  ❌ nobody is signed in on this device. Sign in first, then run this.")
                exit(1)
            case let .refused(reason):
                print("  ❌ the homeserver would not list them: \(reason)")
                exit(1)
            case let .pushers(list):
                pushers = list
            }

            if !pushers.contains(where: \.isOurs) {
                // The first link of the chain, and the one the server cannot see: without the
                // permission there is no `registerForRemoteNotifications`, so no token to register.
                let settings = await UNUserNotificationCenter.current().notificationSettings()
                switch settings.authorizationStatus {
                case .notDetermined: print("  ⚠️  notifications were never asked for on this install")
                case .denied:        print("  ❌ notifications are switched off for Iskra in Settings")
                default:             print("  ✅ notifications are allowed (\(settings.authorizationStatus.rawValue))")
                }
            }

            if pushers.isEmpty {
                print("  ❌ none. This device never registered: the permission was refused, APNs gave")
                print("     no token, or setPusher failed — `log stream --predicate 'subsystem == \"wtf.iskra\"'`")
                print("     shows which (category push).")
                exit(1)
            }

            for pusher in pushers {
                let mark = pusher.isOurs ? "✅" : "⚠️ "
                print("  \(mark) \(pusher.appID)  \(pusher.pushkeyPrefix)  \(pusher.deviceName)  [\(pusher.lang)]")
                print("       → \(pusher.url ?? "no url")  format: \(pusher.format ?? "full")")
            }

            let ours = pushers.filter(\.isOurs)
            guard !ours.isEmpty else {
                print("\n  ❌ none of them is this build's: the app id or the gateway differs. A pusher from")
                print("     another build (or the old moscow.swag.iskra app) does not reach this one.")
                exit(1)
            }

            print("\n  does the gateway deliver to them?")
            var allAccepted = true
            for pusher in ours {
                switch await PusherProbe.deliver(to: pusher) {
                case .accepted:
                    print("  ✅ \(pusher.pushkeyPrefix) accepted — a plain notification should appear now.")
                    print("     If it does not, the gateway and the token are fine: look at the phone's")
                    print("     notification settings for Iskra, and at the homeserver's push rules.")
                case .rejected:
                    allAccepted = false
                    print("  ❌ \(pusher.pushkeyPrefix) rejected by APNs. A Debug build's token is sandbox and")
                    print("     must reach a `platform: sandbox` entry named \(PusherProbe.expectedAppID);")
                    print("     `topic` must be the bundle ID, wtf.iskra. Sygnal's log has APNs's reason.")
                case let .refused(reason):
                    allAccepted = false
                    print("  ❌ \(pusher.pushkeyPrefix) the gateway refused: \(reason)")
                }
            }
            exit(allAccepted ? 0 : 1)
        }

        dispatchMain()
    }
}
