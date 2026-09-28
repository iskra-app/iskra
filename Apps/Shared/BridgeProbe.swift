import Foundation
import IskraCore

/// `Iskra --probe-bridge [address] [homeserver]` sends one real request through the nostr tunnel
/// and says what came back.
///
/// It exists for the same reason as the other probes: every way this feature fails looks the same
/// from inside the app — a sign-in that spins. A key with a typo in it, a bridge that is not
/// running, a bridge whose `ALLOWED_UPSTREAMS` does not cover this homeserver, a closed bridge
/// that has never been told about this device, relays that are all refusing connections: one
/// symptom, five causes. This separates them, on the device, in a signed build, where the
/// interesting failures actually happen.
///
/// With no arguments it uses what is in Settings → Connection, which is the case worth having:
/// somebody has pasted an address, it does not work, and the question is why.
///
/// It drives `BridgeCheck`, the same call the button on that screen makes, so the probe and the
/// screen cannot disagree about the thing they both diagnose.
enum BridgeProbe {
    static var wasRequested: Bool {
        CommandLine.arguments.contains("--probe-bridge")
    }

    /// Words after the flag: the bridge's key, then the homeserver. Both optional.
    private static var arguments: [String] {
        guard let index = CommandLine.arguments.firstIndex(of: "--probe-bridge") else { return [] }
        return Array(CommandLine.arguments.dropFirst(index + 1)).prefix(while: { !$0.hasPrefix("--") })
            .map { $0 }
    }

    static func runAndExit() -> Never {
        let address = arguments.first ?? UserDefaults.standard.string(forKey: TunnelSettings.addressKey) ?? ""
        let homeserverText = arguments.dropFirst().first ?? "matrix.org"
        let homeserver = TunnelSettings.upstreamURL(from: homeserverText) ?? URL(string: "https://matrix.org")!
        let relays = TunnelSettings.relays()

        print("Iskra bridge probe")
        print("  homeserver : \(homeserver.absoluteString)")
        print("  relays     : \(relays.map(\.absoluteString).joined(separator: ", "))")

        guard case .success(let key) = BridgeAddress.publicKey(from: address) else {
            print("  ❌ no bridge address. Paste one in Settings → Connection, or pass it here:")
            print("     Iskra --probe-bridge npub1… [matrix.org]")
            exit(1)
        }
        print("  bridge     : \(BridgeAddress.npub(for: key))")

        let identity = TunnelIdentity()
        if let mine = try? identity.keypair().npub {
            // The one line somebody running a closed bridge needs, and cannot get anywhere else
            // from a terminal.
            print("  this device: \(mine)")
        }

        Task {
            let outcome = await BridgeCheck.run(bridgeKey: key, relays: relays, homeserver: homeserver)
            switch outcome {
            case .reachable(let milliseconds):
                print("  ✅ the bridge answered and the homeserver is behind it — \(milliseconds) ms")
                exit(0)
            case .refused:
                print("  ❌ the bridge refused this homeserver. Its ALLOWED_UPSTREAMS does not cover")
                print("     \(homeserver.absoluteString) — which on matrix.org means both matrix.org")
                print("     and matrix-client.matrix.org.")
                exit(1)
            case .noRelay:
                print("  ❌ no relay would take the request. Is there any network here at all?")
                exit(1)
            case .silent:
                print("  ❌ published, and nothing came back. Either the bridge is not running, or")
                print("     that is not its key, or it is closed and has never been told about this")
                print("     device — add the key printed above to its ALLOWED_PUBKEYS.")
                exit(1)
            case .failed(let reason):
                print("  ❌ \(reason)")
                exit(1)
            }
        }

        dispatchMain()
    }
}
