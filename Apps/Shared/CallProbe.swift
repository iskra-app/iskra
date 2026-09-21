import Foundation
import IskraCore
import MatrixRustSDK

/// `Iskra --probe-call [<roomID>]` says whether this account can place a call, and what URL it
/// would load if it did.
///
/// The first of the two halves calls divide into. Everything here happens before anybody presses
/// anything: whether the homeserver carries MatrixRTC, whether it names an Element Call, whether
/// this room is encrypted and therefore which key scheme the call gets, and finally the widget URL
/// the web view would be pointed at.
///
/// **It runs in the simulator**, and that is the point of it. None of this needs a camera, a
/// microphone or APNs — it needs an account and a server — so the whole decision half of calls can
/// be checked without a device in hand. What it cannot say anything about is whether the call then
/// works, which needs two real devices and is not a thing a probe can fake.
///
/// `#if DEBUG`, like every probe here, and with one extra reason: the URL it prints carries the
/// room ID and the user ID in its query.
enum CallProbe {
    static var wasRequested: Bool {
        CommandLine.arguments.contains("--probe-call")
    }

    private static var roomID: String? {
        guard let i = CommandLine.arguments.firstIndex(of: "--probe-call"),
              CommandLine.arguments.indices.contains(i + 1),
              !CommandLine.arguments[i + 1].hasPrefix("--")
        else {
            return nil
        }
        return CommandLine.arguments[i + 1]
    }

    static func runAndExit() -> Never {
        print("Iskra call probe")
        SDKLogging.start()

        Task { @MainActor in
            guard let session = await restoredSession() else {
                print("  ❌ nobody is signed in on this device.")
                exit(1)
            }

            print("  ⓘ signed in as \(session.userID), server name \(session.serverName)")

            await session.loadCallAvailability()
            let availability = session.callAvailability

            print("  \(availability.serverCarriesCalls ? "✅" : "❌") the homeserver "
                  + "\(availability.serverCarriesCalls ? "knows" : "does not know") a LiveKit focus")

            if let widget = availability.widgetURL {
                print("  ✅ Element Call: \(widget.absoluteString)")
                if BetaFeatures.elementCallURL() != nil {
                    print("     …and that came from the field in Beta features, not from the server.")
                }
            } else {
                print("  ❌ no Element Call address.")
                print("     The server names none under io.element.call in /.well-known/matrix/client,")
                print("     and the app deliberately does not invent one — see ElementCallDiscovery.")
                print("     There is therefore no call button, and that is correct rather than broken.")
            }

            guard availability.isAvailable else { exit(1) }

            guard let roomID else {
                print("  ⓘ pass a room ID to go further: --probe-call '!room:server'")
                exit(0)
            }

            guard let call = session.call(forRoomID: roomID) else {
                print("  ❌ that room could not be reached from this session.")
                exit(1)
            }

            print("  \(await session.canStartCall(inRoomID: roomID) ? "✅" : "❌") "
                  + "this account may start a call in that room (m.call.member)")

            await call.start(intent: .start(video: false), theme: .dark, language: "en")

            switch call.state {
            case let .ready(url):
                print("  ✅ the web view would load:")
                print("     \(url.absoluteString)")
                print("     (room and user IDs are in that query — do not paste it anywhere.)")
                call.stop()
                exit(0)
            case let .failed(failure):
                print("  ❌ the widget would not be built: \(failure)")
                exit(1)
            case .idle, .preparing:
                print("  ❌ the widget never finished being built.")
                exit(1)
            }
        }

        Task {
            try? await Task.sleep(for: .seconds(60))
            print("  ⏱  the probe never finished")
            exit(2)
        }

        dispatchMain()
    }

    /// The signed-in session, or nil. Shared by both call probes.
    static func restoredSession() async -> UserSession? {
        let authentication = AuthenticationService()
        return (try? await authentication.restorePreviousSession()) ?? nil
    }
}
