import Foundation
import IskraCore

/// `Iskra --probe-ring [<roomID> <eventID>]` decrypts a real `m.rtc.notification` and prints what
/// CallKit would have been told about it.
///
/// The honest sibling of `--probe-notification`, and it is worth being exact about what it proves,
/// because the temptation to read more into it is strong.
///
/// **It proves the deciding half, end to end**: the session opens, the event is found and
/// decrypted, the caller's name comes out, the kind of call comes out, the expiry is read, and the
/// checks for "answered somewhere else" and "already over" run against the live room. Everything
/// between "a push arrived" and "this is what the call screen would say" is covered, and all of it
/// works in the simulator, where there is no APNs at all.
///
/// **It proves nothing about PushKit or CallKit.** It runs in the app's own process, started from
/// the command line, with no push behind it. Whether iOS wakes this app for a VoIP push, and
/// whether the system draws a ringing call when it does, is answered only by a real call from a
/// second account to a real device — exactly as `docs/PUSH-GATEWAY.md` says about the extension.
///
/// Given no arguments it goes and finds a recent ring itself, the way `--probe-notification` finds
/// a recent message: nobody has an event ID to hand, and a probe that demanded one is a probe
/// nobody runs.
enum RingProbe {
    static var wasRequested: Bool {
        CommandLine.arguments.contains("--probe-ring")
    }

    private static var arguments: (roomID: String, eventID: String)? {
        guard let i = CommandLine.arguments.firstIndex(of: "--probe-ring"),
              CommandLine.arguments.indices.contains(i + 2),
              !CommandLine.arguments[i + 1].hasPrefix("--"),
              !CommandLine.arguments[i + 2].hasPrefix("--")
        else {
            return nil
        }
        return (CommandLine.arguments[i + 1], CommandLine.arguments[i + 2])
    }

    static func runAndExit() -> Never {
        print("Iskra ring probe")
        SDKLogging.start()

        Task { @MainActor in
            guard let session = await CallProbe.restoredSession() else {
                print("  ❌ nobody is signed in on this device.")
                exit(1)
            }

            guard let (roomID, eventID) = arguments else {
                print("  ⓘ no room and event given, and there is no way to hunt for a ring yet.")
                print("     Place a call from another client, read the event ID out of the room's")
                print("     timeline, and pass both:")
                print("       --probe-ring '!room:server' '$event'")
                exit(0)
            }

            print("  ⓘ room \(roomID)")
            print("  ⓘ event \(eventID)")
            print("  ⓘ CallKit UUID would be \(RingID.uuid(forEventID: eventID))")

            switch await session.resolveRing(roomID: roomID, eventID: eventID) {
            case let .ring(ring):
                print("  ✅ this would ring.")
                print("     name on screen: \(ring.displayTitle)")
                print("     caller:         \(ring.callerName) (\(ring.callerID))")
                print("     kind:           \(ring.isVideo ? "video" : "voice")")
                print("     direct chat:    \(ring.isDirect)")
                if let expires = ring.expiresAt {
                    print("     expires:        \(expires) (in \(Int(expires.timeIntervalSinceNow))s)")
                } else {
                    print("     expires:        the sender did not say")
                }
                print("     would ring for: \(Int(ring.ringingTime()))s")
                exit(0)

            case let .over(reason, ring):
                print("  ⓘ this would be reported to CallKit and then ended: \(reason)")
                if let ring {
                    print("     it was a real ring from \(ring.callerName), just not a live one.")
                }
                print("     Reported anyway — every delivered VoIP push must be, without exception.")
                exit(0)

            case .notSignedIn:
                print("  ❌ the resolver could not find a session, though one was restored above.")
                exit(1)

            case let .failed(reason):
                print("  ❌ the ring would not resolve: \(reason)")
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
}
