import Foundation

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
