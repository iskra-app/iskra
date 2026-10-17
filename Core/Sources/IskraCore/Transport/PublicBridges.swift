import Foundation

/// One bridge from the list of checked public bridges, `github.com/iskra-app/public-bridges`.
///
/// Public is safe to offer only because the bridge is blind: it carries the app's own TLS to the
/// homeserver and sees which host, when and how many bytes — not the token, not the rooms, not a
/// message. A bridge on this list is somebody else's machine, and that is the most it can learn.
public struct PublicBridge: Codable, Sendable, Equatable, Identifiable {
    /// Stable across edits of the entry: it is what the app remembers as "the one I chose".
    public var id: String
    /// What the picker shows.
    public var name: String
    /// The bridge's address, as it prints it at startup.
    public var npub: String
    /// Where to meet it. Several, for the reasons `TunnelSettings.defaultRelays` gives.
    public var relays: [String]
    /// Who runs it — a name a person can recognise, or nothing.
    public var `operator`: String?
    /// Which homeservers it carries streams to: `nil` for any public Matrix server (`*`), or a list
    /// of host names.
    public var homeservers: [String]?

    public init(id: String, name: String, npub: String, relays: [String],
                operator: String? = nil, homeservers: [String]? = nil) {
        self.id = id
        self.name = name
        self.npub = npub
        self.relays = relays
        self.operator = `operator`
        self.homeservers = homeservers
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, npub, relays, `operator`, homeservers
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        npub = try container.decode(String.self, forKey: .npub)
        relays = try container.decode([String].self, forKey: .relays)
        `operator` = try container.decodeIfPresent(String.self, forKey: .operator)
        // `"*"` or a list, as in the bridge's own `ALLOWED_UPSTREAMS`.
        if let any = try? container.decode(String.self, forKey: .homeservers), any == "*" {
            homeservers = nil
        } else {
            homeservers = try container.decodeIfPresent([String].self, forKey: .homeservers)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(npub, forKey: .npub)
        try container.encode(relays, forKey: .relays)
        try container.encodeIfPresent(`operator`, forKey: .operator)
        if let homeservers {
            try container.encode(homeservers, forKey: .homeservers)
        } else {
            try container.encode("*", forKey: .homeservers)
        }
    }

    /// The bridge's 32-byte key, if the entry's address is one.
    public var bridgeKey: Data? {
        guard case .success(let key) = BridgeAddress.publicKey(from: npub) else { return nil }
        return key
    }

    /// The relays that are actually relays — `wss://`, as `TunnelSettings.parseRelays` keeps them.
    public var relayURLs: [URL] {
        TunnelSettings.parseRelays(relays.joined(separator: ","))
    }

    /// Whether the entry can be used at all. An entry that is not is dropped from the list rather
    /// than shown: a bridge in the picker that cannot be connected to is a sign-in that spins.
    var isUsable: Bool {
        !id.isEmpty && id.count <= 64
            && !name.trimmingCharacters(in: .whitespaces).isEmpty && name.count <= 64
            && bridgeKey != nil && !relayURLs.isEmpty
    }
}

/// The file in the repository: `bridges.json` on `main`.
public struct PublicBridgeList: Codable, Sendable, Equatable {
    /// The format's version. A list in a version this build does not know is not read: guessing at
    /// a format is how a bridge gets used for something its entry did not say.
    public var version: Int
    public var bridges: [PublicBridge]

    public static let formatVersion = 1
    /// More than this many entries is not a list of checked bridges, it is a mistake or a flood.
    static let maximumEntries = 200
    /// And more than this many bytes is not worth reading on a phone.
    static let maximumBytes = 256 * 1024

    public init(version: Int = formatVersion, bridges: [PublicBridge]) {
        self.version = version
        self.bridges = bridges
    }

    /// Parse and judge a downloaded or bundled file. Unusable and duplicate entries are dropped
    /// one by one; a file in an unknown version, or not a list at all, is refused whole.
    static func parse(_ data: Data) -> PublicBridgeList? {
        guard data.count <= maximumBytes,
              let list = try? JSONDecoder().decode(PublicBridgeList.self, from: data),
              list.version == formatVersion
        else { return nil }
        var seen = Set<String>()
        let usable = list.bridges.filter { bridge in
            bridge.isUsable && seen.insert(bridge.id).inserted
        }
        return PublicBridgeList(bridges: Array(usable.prefix(maximumEntries)))
    }
}

/// Where the list comes from, and the copy of it the app keeps.
///
/// Three layers, so that the list is there exactly when it is needed — which is when the direct
/// route is blocked, GitHub with it:
///
/// - **a snapshot built into the app** (`Resources/public-bridges.json`), which is never out of
///   reach;
/// - **the last list downloaded**, kept in the App Group, so the notification extension sees the
///   same bridges;
/// - **a fresh download**, at most once a day, from GitHub and then from a CDN that mirrors it.
///
/// The download goes **directly**, not through a bridge — it is how a bridge is found — so it tells
/// GitHub (or the CDN) and the network on the way that this device looked at the list. That is said
/// on the screen, in so many words.
public enum PublicBridges {
    /// The repository people can read, for the screen to name.
    public static let repository = "github.com/iskra-app/public-bridges"

    static let sources = [
        URL(string: "https://raw.githubusercontent.com/iskra-app/public-bridges/main/bridges.json")!,
        URL(string: "https://cdn.jsdelivr.net/gh/iskra-app/public-bridges@main/bridges.json")!,
    ]

    static let listKey = "transport.publicBridges"
    static let fetchedKey = "transport.publicBridgesFetched"
    static let refreshEvery: TimeInterval = 24 * 60 * 60

    /// The list as it stands: the last download if there is one, the built-in snapshot otherwise.
    public static func current(_ defaults: UserDefaults = TunnelSettings.store) -> [PublicBridge] {
        if let data = defaults.data(forKey: listKey), let list = PublicBridgeList.parse(data) {
            return list.bridges
        }
        return bundled.bridges
    }

    /// The snapshot built into this version of the app.
    static let bundled: PublicBridgeList = {
        guard let url = Bundle.module.url(forResource: "public-bridges", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let list = PublicBridgeList.parse(data)
        else { return PublicBridgeList(bridges: []) }
        return list
    }()

    /// Download the list if the copy kept is older than a day. True when a new copy was stored.
    ///
    /// A failure changes nothing: the copy kept, or the snapshot, stays what `current` answers. A
    /// download that parses to no bridges at all is not stored either — a list emptied by mistake
    /// in the repository must not take away the bridge somebody is using right now.
    @discardableResult
    public static func refresh(defaults: UserDefaults = TunnelSettings.store,
                               now: Date = Date(),
                               fetch: @Sendable (URL) async throws -> Data = Self.download) async -> Bool {
        if let last = defaults.object(forKey: fetchedKey) as? Date,
           now.timeIntervalSince(last) < refreshEvery {
            return false
        }
        for source in sources {
            guard let data = try? await fetch(source),
                  let list = PublicBridgeList.parse(data), !list.bridges.isEmpty,
                  let stored = try? JSONEncoder().encode(list)
            else { continue }
            defaults.set(stored, forKey: listKey)
            defaults.set(now, forKey: fetchedKey)
            return true
        }
        return false
    }

    @Sendable public static func download(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        // Never a cached answer from somebody else's proxy: the list is small, and stale is worse.
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }
}
