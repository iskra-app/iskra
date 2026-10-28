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

            // The same service throughout: the OAuth step below needs the client the lookup left
            // behind, and a second `AuthenticationService` would have no sign-in in progress.
            let authentication = AuthenticationService()

            let options: SignInOptions
            do {
                options = try await authentication.startSignIn(homeserverAddress: address)
                print("  ✅ resolved in \(elapsed())s: \(options)")
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

            // And the step the lookup used to stop short of, which is the step that was actually
            // broken. Everything up to here is the app asking the server how it lets people in;
            // this is the app asking for the address to send them to — and it registers an OAuth
            // client with the server on the way, which is a thing that can be *refused*. It was.
            //
            // No credentials are needed for this, which is why the probe can do it: nobody is signed
            // in or out by asking where the browser should go.
            guard options.canUseSingleSignOn else {
                print("  ⓘ this server has no OAuth, so there is no browser step to probe.")
                exit(0)
            }

            do {
                let url = try await authentication.singleSignOnURL()
                // The host and path only. The query carries the client ID, the PKCE challenge and
                // the state — none of which is a secret exactly, and all of which is noise.
                let shown = "\(url.scheme ?? "?")://\(url.host() ?? "?")\(url.path())"
                print("  ✅ the browser would open: \(shown)")
                print("     OAuth is working end to end, up to the point a human takes over.")
                exit(0)
            } catch {
                print("  ❌ could not get the OAuth URL in \(elapsed())s.")
                print("     \(error)")
                print()
                print("     This is where the sign-in dies before the browser ever opens. The usual")
                print("     cause is the redirect URI: an authentication service will refuse a")
                print("     private-use scheme that is not the reverse-DNS of the client's own")
                print("     domain — client_uri https://iskra.wtf permits wtf.iskra:,")
                print("     and nothing else. See AppEnvironment.oauthRedirectURI.")
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
