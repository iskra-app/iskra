import Foundation
import Synchronization

/// The user's choice about routing traffic through a bridge, and where that choice is written down.
///
/// The key lives here rather than in the view because the model layer is what acts on it:
/// `AuthenticationService` reads it when it builds a client, long before any screen exists.
public enum TunnelSettings {
    public static let enabledKey = "transport.bridgeEnabled"

    public static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: enabledKey)
    }

    /// Turn what the user typed into something to connect to.
    ///
    /// The sign-in screen takes a server *name* (`matrix.org`), restoring takes a full URL. Both
    /// end up here, and a bare name means `https` — never `http`, which on this path would be a
    /// silent downgrade of the one leg of the journey that is still real TLS.
    public static func upstreamURL(from address: String) -> URL? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.contains("://") { return URL(string: trimmed) }
        return URL(string: "https://\(trimmed)")
    }

    // MARK: - What the listener is standing in for

    /// The real homeserver behind the loopback address, for as long as the listener is up.
    ///
    /// A process-wide register rather than a value passed around, because of who needs to read it:
    /// `SessionDelegate.saveSessionInKeychain` is called *synchronously from a Rust thread* in the
    /// middle of a token refresh, has no actor to await and no route back to whoever built the
    /// client. There is only ever one listener in a process, so one register is the honest shape.
    private static let standIn = Mutex<String?>(nil)

    /// Called when the listener comes up, and again when `.well-known` reveals where the homeserver
    /// really lives — `matrix.org` delegates to `matrix-client.matrix.org`, and it is the second
    /// address that every request after discovery belongs to.
    public static func listenerStandsIn(for homeserver: URL) {
        standIn.withLock { $0 = homeserver.absoluteString }
    }

    public static func listenerStoppedStandingIn() {
        standIn.withLock { $0 = nil }
    }

    /// Whether this address is one of our own listeners rather than a homeserver.
    public static func isLoopback(_ url: String) -> Bool {
        guard let host = URL(string: url)?.host()?.lowercased() else { return false }
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }

    /// The address worth writing down, given the one the SDK believes in.
    ///
    /// **A loopback address must never reach the Keychain.** It carries a port the system handed
    /// out for this launch only; written down, it is read back next launch as the address of
    /// nothing at all, and the app reports "no network" pointing at a port that closed when it
    /// last quit. Persisting the homeserver the listener stands in for keeps the record true
    /// whether or not the switch is on the next time.
    public static func persistableHomeserver(_ url: String) -> String {
        guard isLoopback(url) else { return url }
        return standIn.withLock { $0 } ?? url
    }
}

/// What the transport is actually doing, for the screen to show.
///
/// Deliberately without a `.connected` that would mean "you are protected": nothing in this build
/// reaches a bridge yet, and a status that implied otherwise would be the worst kind of lie an app
/// of this sort can tell.
public enum TunnelStatus: Sendable, Equatable {
    /// The switch is off; the SDK talks to the homeserver directly.
    case off
    /// The local listener is up and the SDK's traffic goes through it — but onward from there it
    /// still goes straight to the homeserver. No nostr, no bridge, no circumvention yet.
    case routingLocally(port: UInt16)
    /// The listener could not be started. Traffic went direct rather than nowhere.
    case failed(String)
}
