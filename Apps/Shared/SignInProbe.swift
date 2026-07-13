import Foundation
import IskraCore
import MatrixRustSDK

/// `Iskra --probe-signin <address>` runs the real sign-in lookup and says where it stops.
///
/// Same reasoning as `StorageCheck`: the interesting failures only happen inside a
/// signed, installed app on a real device, where there is no debugger attached and
/// nothing on screen but a spinner. This drives `AuthenticationService.startSignIn`
/// — the exact call the "Continue" button makes — with the SDK's own tracing turned
/// on, and prints a heartbeat so a hang is visibly a hang rather than a slow answer.
enum SignInProbe {
    static var wasRequested: Bool {
        CommandLine.arguments.contains("--probe-signin")
    }

    private static var address: String {
        guard let i = CommandLine.arguments.firstIndex(of: "--probe-signin"),
              CommandLine.arguments.indices.contains(i + 1) else { return "matrix.org" }
        return CommandLine.arguments[i + 1]
    }

    static func runAndExit() -> Never {
        print("Iskra sign-in probe → \(address)")

        SDKLogging.start()

        let started = Date()
        Task {
            while true {
                try? await Task.sleep(for: .seconds(2))
                print("  … still waiting, \(Int(Date().timeIntervalSince(started)))s")
            }
        }

        Task {
            let elapsed = { Int(Date().timeIntervalSince(started)) }
            do {
                let options = try await AuthenticationService().startSignIn(homeserverAddress: address)
                print("  ✅ resolved in \(elapsed())s: \(options)")
                exit(0)
            } catch let AuthenticationError.storageUnavailable(cause) {
                print("  ❌ storage is unavailable — this is the App Group or the Keychain group,")
                print("     not the address. Run --verify-storage, which says which: \(cause)")
                exit(1)
            } catch AuthenticationError.homeserverUnreachable {
                print("  ❌ the server never answered (\(elapsed())s). Reachable from the phone?")
                exit(1)
            } catch {
                print("  ❌ failed in \(elapsed())s: \(error)")
                exit(1)
            }
        }

        // startSignIn is bounded now, so it always answers. If this fires anyway, the
        // timeout itself is broken and that is the finding.
        Task {
            try? await Task.sleep(for: .seconds(90))
            print("  ⏱  startSignIn never returned, even with its timeout")
            exit(2)
        }

        dispatchMain()
    }
}
