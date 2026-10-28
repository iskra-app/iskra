import Foundation

/// The user's choice about routing traffic through a bridge, and where that choice is written down.
///
/// The key lives here rather than in the view because the model layer is what acts on it:
/// `AuthenticationService` reads it when it builds a client, long before any screen exists.
public enum TunnelSettings {
    public static let enabledKey = "transport.bridgeEnabled"
    /// The bridge's public key, as the person pasted it: hex or `npub1…`. No value at all means
    /// `defaultAddress`; an empty one means no bridge.
    public static let addressKey = "transport.bridgeAddress"
    /// The relays to meet it on, one per line or separated by commas.
    public static let relaysKey = "transport.bridgeRelays"

    /// The bridge the Iskra developers run, open to any public Matrix server. What the address
    /// field holds until somebody types another — so turning the switch on is all it takes.
    public static let defaultAddress = "npub1dwztf356tpg2lvzv8z74qgx68efhk0aq7yv2xr4tfq4pnsr92musk5k06v"

    /// Keys from the builds that kept a public list and several bridges of one's own. Read once,
    /// to carry the bridge that was in use into the address field, and then removed.
    static let retiredKeys = ["transport.customBridges", "transport.bridgeSource", "transport.chosenBridge",
                              "transport.publicBridges", "transport.publicBridgesFetched"]

    /// Where these settings are kept: the App Group's defaults, not `.standard`.
    ///
    /// Because the notification extension builds a client too. Inside an `.appex`, `.standard` is
    /// the extension's own and empty, so with the settings kept there the extension read "no
    /// bridge" and fetched and decrypted every push **straight from the homeserver** — for a user
    /// who had turned the bridge on precisely because that route is watched or blocked, while the
    /// screen said "through the bridge". The same trap as `BetaFeatures.faceStore`, on the setting
    /// where it matters most.
    ///
    /// `.standard` where there is no App Group, which is a standalone build with no extension.
    /// Reading it carries whatever an older build left in `.standard` across, once.
    public static var store: UserDefaults {
        _ = adopted
        return ChatDirectory.sharedDefaults ?? .standard
    }

    /// Once per process, and only for a key the shared suite has no value for yet — so a setting
    /// changed after the move is never undone by the value it used to have.
    private static let adopted: Void = {
        guard let shared = ChatDirectory.sharedDefaults else { return }
        let local = UserDefaults.standard
        for key in [enabledKey, addressKey, relaysKey] {
            guard shared.object(forKey: key) == nil, let value = local.object(forKey: key) else { continue }
            shared.set(value, forKey: key)
        }
        retireBridgeList(shared)
    }()

    /// The bridge in use under the retired keys, carried into the address field: somebody who had
    /// picked a bridge of their own keeps it. A public one was only ever `defaultAddress`, which
    /// an untouched field already means.
    static func retireBridgeList(_ defaults: UserDefaults) {
        guard retiredKeys.contains(where: { defaults.object(forKey: $0) != nil }) else { return }
        struct Entry: Decodable { var npub: String; var relays: [String] }
        struct Chosen: Decodable { var source: String; var bridge: Entry }
        if let data = defaults.data(forKey: "transport.chosenBridge"),
           let chosen = try? JSONDecoder().decode(Chosen.self, from: data) {
            if chosen.source == "custom" {
                defaults.set(chosen.bridge.npub, forKey: addressKey)
                let relays = chosen.bridge.relays == defaultRelays ? "" : chosen.bridge.relays.joined(separator: "\n")
                defaults.set(relays, forKey: relaysKey)
            } else {
                defaults.removeObject(forKey: addressKey)
                defaults.removeObject(forKey: relaysKey)
            }
        }
        retiredKeys.forEach(defaults.removeObject(forKey:))
    }

    public static func isEnabled(_ defaults: UserDefaults = store) -> Bool {
        defaults.bool(forKey: enabledKey)
    }

    /// What the address field holds: what was typed, or `defaultAddress` if nothing ever was.
    public static func address(_ defaults: UserDefaults = store) -> String {
        defaults.string(forKey: addressKey) ?? defaultAddress
    }

    /// Whether anything at all is in the address field.
    ///
    /// Not the same question as `bridgeKey() != nil`, and the difference is the whole point: an
    /// empty field is "no bridge", while a field holding a mistyped `npub` is a bridge the user
    /// meant to use and cannot — which must be a refusal, never a quiet direct connection.
    public static func hasAddress(_ defaults: UserDefaults = store) -> Bool {
        !address(defaults).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Whether the settings ask for a bridge — which means a connection that cannot get one is a
    /// refusal and never a quiet direct one.
    public static func asksForBridge(_ defaults: UserDefaults = store) -> Bool {
        isEnabled(defaults) && hasAddress(defaults)
    }

    /// The bridge's 32-byte public key, if the address field holds a usable one.
    ///
    /// `nil` is not an error state by itself — an emptied field. What it must never come to mean is
    /// "carry on without a bridge" while `asksForBridge` says one was asked for.
    public static func bridgeKey(_ defaults: UserDefaults = store) -> Data? {
        guard case .success(let key) = BridgeAddress.publicKey(from: address(defaults)) else { return nil }
        return key
    }

    /// Relays the tunnel meets the bridge on.
    ///
    /// Several by default, and not as a spare tyre: an event is published to all of them at once
    /// and the answer comes back from whichever is quickest, so a relay that is down — and
    /// `relay.damus.io` answers `503` to the connection itself often enough to be the example —
    /// costs nothing. These are the ones `run-local.sh` in iskra-bridge starts with, so a bridge raised by
    /// that script and a client that was told nothing about relays already agree.
    ///
    /// Chosen by where they are reachable *from*, not by how popular they are. Measured from Moscow
    /// in October 2026, home Wi-Fi and MTS: relays on Hetzner, Contabo, DigitalOcean and most of
    /// Cloudflare connect, answer a ping, and then stop dead at ~16 KB — which is every relay this
    /// list used to have (`nos.lol`, `relay.nostr.band`) but one. A tunnel carries a whole sync
    /// through its relay, so a relay that passes a ping and nothing more is no relay at all.
    /// `offchain.pub` and `nostr.bitcoiner.social` share a hoster; `relay.primal.net` passed on one
    /// network out of two and is last.
    public static let defaultRelays = ["wss://relay.snort.social",
                                       "wss://nostr.wine",
                                       "wss://offchain.pub",
                                       "wss://nostr.bitcoiner.social",
                                       "wss://relay.primal.net"]

    public static func relays(_ defaults: UserDefaults = store) -> [URL] {
        let parsed = parseRelays(defaults.string(forKey: relaysKey) ?? "")
        return parsed.isEmpty ? defaultRelays.compactMap(URL.init(string:)) : parsed
    }

    // MARK: - Applying a change

    /// What a connection is built from, as it would be read at the moment of building.
    ///
    /// The *effective* values, not the text in the fields: a space after the key, `npub` pasted over
    /// the same key in hex, a relay list emptied back to the defaults — none of those changes the
    /// connection, and none of them should tear a session down to rebuild it identically.
    public struct Snapshot: Equatable, Sendable {
        public var enabled: Bool
        public var bridgeKey: Data?
        public var relays: [URL]
    }

    public static func snapshot(_ defaults: UserDefaults = store) -> Snapshot {
        Snapshot(enabled: isEnabled(defaults), bridgeKey: bridgeKey(defaults), relays: relays(defaults))
    }

    /// Posted when the connection settings have changed in a way the live session has to be rebuilt
    /// for. The root view answers it — closing the session and restoring it again, which is what a
    /// relaunch used to be needed for.
    ///
    /// Needed at all because a Matrix client is built *around* its connection: with the switch on it
    /// goes through this app's own proxy, and with it off, straight out. A live client cannot be
    /// moved from one to the other, so flipping the switch did nothing until the
    /// next launch — and in a place where the direct route is blocked, "nothing" was an app that
    /// stopped loading messages the moment somebody reached for the thing that would fix it.
    public static let changed = Notification.Name("wtf.iskra.tunnelSettingsChanged")

    /// Split on commas and newlines, and keep what is actually a relay address.
    ///
    /// `https://` is dropped rather than corrected. A relay is reached over `wss://`, and quietly
    /// rewriting one scheme into another turns a typo into a relay that merely looks down.
    public static func parseRelays(_ text: String) -> [URL] {
        text.split(whereSeparator: { $0 == "," || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .compactMap { URL(string: $0) }
            // `ws://` only to this machine, which is how a relay under test is reached. Anywhere
            // else it is both keys, the timing and the sizes of every request in clear text on
            // the network — the content is sealed, the fact of it is not.
            .filter { $0.scheme == "wss" || ($0.scheme == "ws" && isLoopback($0.absoluteString)) }
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

    /// Whether this address is this machine.
    public static func isLoopback(_ url: String) -> Bool {
        guard let host = URL(string: url)?.host()?.lowercased() else { return false }
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }

    /// Whether this is the address of one of this app's own HTTP listeners — loopback, and plain
    /// `http`, because that is all they speak. What `restoreClient` repairs: an account signed in
    /// while the bridge's first protocol stood a listener in for the homeserver, from before the
    /// app learnt never to write that address down. A loopback `https` address is somebody's real
    /// server behind real TLS — the blind-route tests' homeserver — and is left alone.
    public static func isOurListener(_ url: String) -> Bool {
        isLoopback(url) && URL(string: url)?.scheme?.lowercased() == "http"
    }
}

/// What the transport is actually doing, for the screen to show.
///
/// Every case says what is true of the traffic *now*, never what was chosen. A status that implied
/// protection there was none of would be the worst kind of lie an app of this sort can tell — which
/// is why the switch on with no bridge address is `.off`: nothing is in the way, and the SDK talks
/// to the homeserver directly.
public enum TunnelStatus: Sendable, Equatable {
    /// No bridge: the SDK talks to the homeserver directly.
    case off
    /// The tunnel is up, with this many relays connected, and the bridge has not connected a
    /// stream yet. Nothing is said about what it cannot see until it has carried something.
    case connecting(relays: Int)
    /// The bridge has connected this device's streams: every connection leaves as encrypted nostr
    /// events, and the TLS inside them is the app's own, end to end to the homeserver. The one
    /// case in which the screen may say "the bridge cannot see your messages" — because it is now
    /// true of traffic that is actually flowing, not of a setting.
    case bridgedBlind(relays: Int)
    /// The bridge answered and would not take this device to its server.
    case refused(BridgeRefusal)
    /// The listener could not be started, or the bridge could not be reached.
    case failed(String)

    /// A raised tunnel's status, from what the bridge has said so far. The last settled stream
    /// decides between "refused" and the rest: a bridge that turned the last stream away is
    /// refusing *now*, even if it carried an earlier one; and "cannot see" waits for a stream the
    /// bridge actually connected.
    init(heard: Heard, relays: Int) {
        if case .reset(let reason) = heard.last {
            let refusal = BridgeRefusal(reason: reason)
            if refusal.isRefusal {
                self = .refused(refusal)
                return
            }
        }
        self = heard.everOpened ? .bridgedBlind(relays: relays) : .connecting(relays: relays)
    }
}
