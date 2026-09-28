import Foundation
import Synchronization

/// The user's choice about routing traffic through a bridge, and where that choice is written down.
///
/// The key lives here rather than in the view because the model layer is what acts on it:
/// `AuthenticationService` reads it when it builds a client, long before any screen exists.
public enum TunnelSettings {
    public static let enabledKey = "transport.bridgeEnabled"
    /// The bridge's public key, as the person pasted it: hex or `npub1…`.
    public static let addressKey = "transport.bridgeAddress"
    /// The relays to meet it on, one per line or separated by commas.
    public static let relaysKey = "transport.bridgeRelays"

    public static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: enabledKey)
    }

    // MARK: - Which bridge, and where to meet it

    /// The bridge's 32-byte public key, if the settings hold a usable one.
    ///
    /// `nil` is not an error state — it is the ordinary case of somebody turning the switch on
    /// before pasting an address. What it must never come to mean is "carry on without a bridge".
    public static func bridgeKey(_ defaults: UserDefaults = .standard) -> Data? {
        guard let text = defaults.string(forKey: addressKey),
              case .success(let key) = BridgeAddress.publicKey(from: text)
        else { return nil }
        return key
    }

    /// Relays the tunnel meets the bridge on.
    ///
    /// Several by default, and not as a spare tyre: an event is published to all of them at once
    /// and the answer comes back from whichever is quickest, so a relay that is down — and
    /// `relay.damus.io` answers `503` to the connection itself often enough to be the example —
    /// costs nothing. These are the three `Bridge/run-local.sh` starts with, so a bridge raised by
    /// that script and a client that was told nothing about relays already agree.
    public static let defaultRelays = ["wss://nos.lol",
                                       "wss://relay.primal.net",
                                       "wss://relay.nostr.band"]

    public static func relays(_ defaults: UserDefaults = .standard) -> [URL] {
        let parsed = parseRelays(defaults.string(forKey: relaysKey) ?? "")
        return parsed.isEmpty ? defaultRelays.compactMap(URL.init(string:)) : parsed
    }

    /// Split on commas and newlines, and keep what is actually a relay address.
    ///
    /// `https://` is dropped rather than corrected. A relay is reached over `wss://`, and quietly
    /// rewriting one scheme into another turns a typo into a relay that merely looks down.
    public static func parseRelays(_ text: String) -> [URL] {
        text.split(whereSeparator: { $0 == "," || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .compactMap { URL(string: $0) }
            .filter { $0.scheme == "wss" || $0.scheme == "ws" }
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
/// Every case says what is true of the traffic *now*, never what was chosen. A status that implied
/// protection there was none of would be the worst kind of lie an app of this sort can tell — which
/// is why `.routingLocally` is still here and still says what it says: with the switch on and no
/// bridge address filled in, the listener comes up and the requests still go straight at the
/// homeserver.
public enum TunnelStatus: Sendable, Equatable {
    /// The switch is off; the SDK talks to the homeserver directly.
    case off
    /// The local listener is up and the SDK's traffic goes through it — but onward from there it
    /// still goes straight to the homeserver. No nostr, no bridge, no circumvention.
    case routingLocally(port: UInt16)
    /// Every request leaves as an encrypted nostr event, with this many relays connected.
    case bridged(relays: Int)
    /// The listener could not be started, or the bridge could not be reached.
    case failed(String)
}
