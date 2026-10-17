import Foundation

/// The user's choice about routing traffic through a bridge, and where that choice is written down.
///
/// The key lives here rather than in the view because the model layer is what acts on it:
/// `AuthenticationService` reads it when it builds a client, long before any screen exists.
public enum TunnelSettings {
    public static let enabledKey = "transport.bridgeEnabled"
    /// The person's own bridges, as JSON: `[PublicBridge]` — the same shape as an entry on the
    /// public list, with an id of the app's making.
    public static let customBridgesKey = "transport.customBridges"
    /// Which kind of bridge is in use: one from the public list, or one of the person's own.
    public static let sourceKey = "transport.bridgeSource"
    /// The bridge in use, the whole entry as JSON — not only its id, so that the notification
    /// extension can connect to it without either list, and so that a public entry that leaves the
    /// list does not silently become another bridge.
    public static let chosenBridgeKey = "transport.chosenBridge"

    /// The single bridge address and relay list from before a person could have several. Read once,
    /// to carry them into `customBridgesKey`, and never written again.
    public static let addressKey = "transport.bridgeAddress"
    public static let relaysKey = "transport.bridgeRelays"

    public enum Source: String, Sendable {
        /// A bridge from `github.com/iskra-app/public-bridges`.
        case publicList = "public"
        /// One of the person's own.
        case custom
    }

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
    }()

    public static func isEnabled(_ defaults: UserDefaults = store) -> Bool {
        defaults.bool(forKey: enabledKey)
    }

    // MARK: - One's own bridges

    /// The person's own bridges, oldest first.
    ///
    /// The first time it is asked, a bridge typed into the old single address field becomes the
    /// first of them — and the one in use, if it was — so that nobody who set up a bridge before
    /// there could be several finds it gone.
    public static func customBridges(_ defaults: UserDefaults = store) -> [PublicBridge] {
        if let data = defaults.data(forKey: customBridgesKey) {
            return ((try? JSONDecoder().decode([PublicBridge].self, from: data)) ?? []).filter(\.isUsable)
        }
        return migrateLegacy(defaults)
    }

    /// Add one's own bridge, or replace the one with the same id. Returns the entry as stored.
    @discardableResult
    public static func saveCustom(name: String, address: String, relays: String, id: String? = nil,
                                  _ defaults: UserDefaults = store) -> PublicBridge? {
        guard case .success(let key) = BridgeAddress.publicKey(from: address) else { return nil }
        let typed = parseRelays(relays).map(\.absoluteString)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let npub = BridgeAddress.npub(for: key)
        let bridge = PublicBridge(id: id ?? UUID().uuidString,
                                  name: String((trimmed.isEmpty ? shortName(npub) : trimmed).prefix(64)),
                                  npub: npub,
                                  relays: typed.isEmpty ? defaultRelays : typed)
        var all = customBridges(defaults)
        if let index = all.firstIndex(where: { $0.id == bridge.id }) {
            all[index] = bridge
        } else {
            all.append(bridge)
        }
        write(all, defaults)
        // The one in use, edited, is still the one in use — with its new address.
        if source(defaults) == .custom, chosenEntry(defaults)?.id == bridge.id {
            choose(bridge, source: .custom, defaults)
        }
        return bridge
    }

    /// Forget one of one's own bridges. If it was the one in use, none of one's own is in use now.
    public static func removeCustom(id: String, _ defaults: UserDefaults = store) {
        write(customBridges(defaults).filter { $0.id != id }, defaults)
        if source(defaults) == .custom, chosenEntry(defaults)?.id == id {
            defaults.removeObject(forKey: chosenBridgeKey)
        }
    }

    private static func write(_ bridges: [PublicBridge], _ defaults: UserDefaults) {
        defaults.set(try? JSONEncoder().encode(bridges), forKey: customBridgesKey)
    }

    private static func migrateLegacy(_ defaults: UserDefaults) -> [PublicBridge] {
        let address = (defaults.string(forKey: addressKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard case .success(let key) = BridgeAddress.publicKey(from: address) else {
            write([], defaults)
            return []
        }
        let typed = parseRelays(defaults.string(forKey: relaysKey) ?? "").map(\.absoluteString)
        let npub = BridgeAddress.npub(for: key)
        let bridge = PublicBridge(id: UUID().uuidString, name: shortName(npub), npub: npub,
                                  relays: typed.isEmpty ? defaultRelays : typed)
        write([bridge], defaults)
        if defaults.string(forKey: sourceKey) == nil {
            choose(bridge, source: .custom, defaults)
        }
        return [bridge]
    }

    /// `npub1abcd…wxyz`: what a bridge is called until somebody names it, and how its address is
    /// shown under its name.
    public static func shortAddress(_ npub: String) -> String { shortName(npub) }

    static func shortName(_ npub: String) -> String {
        guard npub.count > 16 else { return npub }
        return "\(npub.prefix(9))…\(npub.suffix(4))"
    }

    // MARK: - Which bridge is in use

    /// Which kind of bridge. Nothing chosen means the public list — unless the person has bridges
    /// of their own, which they set up on purpose and must keep using.
    public static func source(_ defaults: UserDefaults = store) -> Source {
        if let raw = defaults.string(forKey: sourceKey), let source = Source(rawValue: raw) { return source }
        return customBridges(defaults).isEmpty ? .publicList : .custom
    }

    /// The bridge in use, whichever kind it is.
    ///
    /// - **Public:** the one chosen, or the first on the list when none has been. A chosen bridge
    ///   stays chosen even after it leaves the list — it was stored whole — because swapping in
    ///   another bridge behind the person's back is the one thing the switch must never do; the
    ///   screen says it is no longer listed.
    /// - **Own:** the one chosen, while it still exists; deleted, there is none.
    public static func chosenBridge(_ defaults: UserDefaults = store) -> PublicBridge? {
        switch source(defaults) {
        case .publicList:
            return chosenEntry(defaults) ?? PublicBridges.current(defaults).first
        case .custom:
            let own = customBridges(defaults)
            guard let chosen = chosenEntry(defaults) else { return own.first }
            return own.first { $0.id == chosen.id }
        }
    }

    /// The entry stored as chosen, of the kind in use — a public entry is no answer for "which of
    /// my own", and the other way round.
    private static func chosenEntry(_ defaults: UserDefaults) -> PublicBridge? {
        guard let data = defaults.data(forKey: chosenBridgeKey),
              let stored = try? JSONDecoder().decode(ChosenBridge.self, from: data),
              stored.source == (defaults.string(forKey: sourceKey) ?? ""), stored.bridge.isUsable
        else { return nil }
        return stored.bridge
    }

    /// Whether a bridge of the kind in use has been chosen — rather than defaulted to.
    public static func hasChosen(_ defaults: UserDefaults = store) -> Bool {
        chosenEntry(defaults) != nil
    }

    private struct ChosenBridge: Codable {
        var source: String
        var bridge: PublicBridge
    }

    /// Use this bridge from now on.
    public static func choose(_ bridge: PublicBridge, source: Source, _ defaults: UserDefaults = store) {
        defaults.set(source.rawValue, forKey: sourceKey)
        defaults.set(try? JSONEncoder().encode(ChosenBridge(source: source.rawValue, bridge: bridge)),
                     forKey: chosenBridgeKey)
    }

    /// Whether the settings ask for a bridge — which, with the switch on, means a connection that
    /// cannot get one is a refusal and never a quiet direct one. A public bridge is always asked
    /// for, even while the list is empty; one's own, as soon as there is one.
    public static func asksForBridge(_ defaults: UserDefaults = store) -> Bool {
        guard isEnabled(defaults) else { return false }
        switch source(defaults) {
        case .publicList: return true
        case .custom: return !customBridges(defaults).isEmpty
        }
    }

    /// The 32-byte public key of the bridge in use, if there is one.
    ///
    /// `nil` is not an error state by itself — somebody who turned the switch on and has not yet
    /// picked a bridge of their own. What it must never come to mean is "carry on without a bridge"
    /// while `asksForBridge` says one was asked for.
    public static func bridgeKey(_ defaults: UserDefaults = store) -> Data? {
        chosenBridge(defaults)?.bridgeKey
    }

    /// Relays the tunnel meets the bridge on.
    ///
    /// Several by default, and not as a spare tyre: an event is published to all of them at once
    /// and the answer comes back from whichever is quickest, so a relay that is down — and
    /// `relay.damus.io` answers `503` to the connection itself often enough to be the example —
    /// costs nothing. These are the ones `Bridge/run-local.sh` starts with, so a bridge raised by
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
        let chosen = chosenBridge(defaults)?.relayURLs ?? []
        return chosen.isEmpty ? defaultRelays.compactMap(URL.init(string:)) : chosen
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
    public static let changed = Notification.Name("moscow.swag.iskra.tunnelSettingsChanged")

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
