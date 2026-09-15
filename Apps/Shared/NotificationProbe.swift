import Foundation
import IskraCore

/// `Iskra --probe-notification <roomID> <eventID>` decrypts one event exactly the way the
/// notification extension will, and prints what would have gone on the lock screen.
///
/// It exists because of a dependency the roadmap drew too widely. Stage 7 says not to start
/// until a push gateway answers — but a gateway does not decrypt anything. It delivers a
/// room ID and an event ID, and *those two strings are all a push contains*. So the work of
/// the stage — finding an event by ID in an encrypted store and reading it — needs no
/// gateway, no APNs and no device token. It needs two identifiers, and here they are typed
/// in by hand.
///
/// Be exact about what this proves, because it is easy to claim more:
///
/// - It **does** prove `PushDecoder` end to end — the session restores, the notification
///   client comes up in `.multipleProcesses`, the event is found, the keys decrypt it, and
///   the words that come out are the words that would go on the lock screen.
/// - It **does not** prove the *extension's* entitlements. This runs in the app's process,
///   which already has the App Group; the `.appex` is a different bundle ID and is granted
///   the group and the Keychain separately. That is checked by `codesign -d --entitlements`
///   on the built extension, and confirmed for real only when a push actually arrives.
/// - It **does not** prove that iOS wakes the extension at all. Nothing but a real push can.
///
/// Run it signed and signed-in. Any message in any chat will do; the SDK's own log prints
/// event IDs, or take one from the room's timeline.
enum NotificationProbe {
    static var wasRequested: Bool {
        CommandLine.arguments.contains("--probe-notification")
    }

    static func runAndExit() -> Never {
        print("Iskra push probe")

        SDKLogging.start()

        Task {
            let decoder = PushDecoder()

            // Given a room and an event, decrypt those. Given nothing, go and find a real
            // message — because nobody has an event ID to hand, and a probe that demands one
            // before it will run is a probe that never runs. See `RecentMessage`.
            let arguments = CommandLine.arguments
            let flag = arguments.firstIndex(of: "--probe-notification") ?? 0
            let target: (roomID: String, eventID: String)?

            if arguments.count > flag + 2 {
                target = (arguments[flag + 1], arguments[flag + 2])
            } else {
                print("  no room and event given — looking for a recent message…")
                target = await decoder.recentMessage()
            }

            guard let (roomID, eventID) = target else {
                print("  ❌ no message found to try. Sign in, and say something in a chat.")
                exit(1)
            }

            print("  room  \(roomID)")
            print("  event \(eventID)")

            switch await decoder.notification(roomID: roomID, eventID: eventID) {
            case let .show(notification):
                // Deliberately printed, and worth being uneasy about: this is a decrypted
                // message on a console. It is the user's own message, on the user's own
                // device, at the user's explicit request — and the entire question this probe
                // exists to answer is whether the words come out right, which cannot be
                // answered without looking at them. `Log.push` never does this.
                print("  ✅ decrypted — this is what would land on the lock screen:")
                print("     title    \(notification.title)")
                if let sender = notification.sender {
                    print("     sender   \(sender)")
                }
                print("     body     \(notification.body)")
                print("     sound    \(notification.isNoisy ? "yes" : "no")")

                // The face, and whether it arrived. Printed because "there is no avatar on the
                // notification" has three different causes that look identical on a lock screen:
                // the sender has no picture, the picture did not arrive in the two seconds it is
                // given, or it arrived and iOS drew the notification plainly anyway. These two
                // lines separate the first two from the third without a word of guesswork.
                print("     person   \(notification.personName ?? "—") \(notification.personID ?? "")")
                switch (notification.avatarURL, notification.avatar) {
                case (nil, _):
                    print("     avatar   none — this sender has no picture set")
                case let (url?, nil):
                    print("     avatar   NOT FETCHED — \(url)")
                    print("              The URL is there and the bytes are not: either the two-second")
                    print("              budget ran out or the download failed. `Log.push` says which.")
                case let (_, bytes?):
                    print("     avatar   \(bytes.count) bytes")
                }

                print("     (The extension's own entitlements are not proved by this — see above.)")
                exit(0)

            case let .silence(reason):
                print("  ✅ decrypted, and deliberately not shown: \(reason)")
                print("     The store opened and the event was read, which is what this proves.")
                exit(0)

            case .notSignedIn:
                print("  ❌ nobody is signed in on this device. Sign in first, then run this.")
                exit(1)

            case let .failed(reason):
                print("  ❌ \(reason)")
                print("     If this is an App Group or Keychain refusal, the extension's own")
                print("     entitlements are the thing to look at — they are granted separately")
                print("     from the app's. `Iskra --verify-storage` checks the app's side.")
                exit(1)
            }
        }

        dispatchMain()
    }
}
