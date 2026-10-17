import Foundation
import Testing
@testable import IskraCore

/// Which bridge is in use: one from the public list, or one of the person's own — and the rules
/// that keep a choice from quietly becoming another bridge, or no bridge.
@Suite("Bridge choice")
struct TunnelChoiceTests {
    private func fresh() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "choice-\(UUID().uuidString)"))
    }

    private func entry(_ name: String) throws -> PublicBridge {
        PublicBridge(id: name, name: name, npub: try NostrKeypair.generate().npub,
                     relays: ["wss://relay.example"])
    }

    private func list(_ bridges: [PublicBridge], into defaults: UserDefaults) throws {
        defaults.set(try JSONEncoder().encode(PublicBridgeList(bridges: bridges)), forKey: PublicBridges.listKey)
    }

    @Test("with nothing chosen, the first public bridge is the one in use")
    func publicByDefault() throws {
        let defaults = try fresh()
        #expect(TunnelSettings.source(defaults) == .publicList)
        #expect(TunnelSettings.bridgeKey(defaults) == nil)

        let first = try entry("first")
        try list([first, try entry("second")], into: defaults)
        #expect(TunnelSettings.chosenBridge(defaults) == first)
        #expect(TunnelSettings.relays(defaults).map(\.absoluteString) == ["wss://relay.example"])
    }

    /// Somebody who set up a bridge before there could be several keeps it, as their own and in use.
    @Test("the old single address becomes one's own first bridge, in use")
    func theOldAddressIsCarriedOver() throws {
        let defaults = try fresh()
        let keys = try NostrKeypair.generate()
        defaults.set(" \(Hex.string(keys.publicKey)) ", forKey: TunnelSettings.addressKey)
        defaults.set("wss://mine.example", forKey: TunnelSettings.relaysKey)

        let own = TunnelSettings.customBridges(defaults)
        #expect(own.count == 1)
        #expect(own.first?.npub == keys.npub)
        #expect(TunnelSettings.source(defaults) == .custom)
        #expect(TunnelSettings.bridgeKey(defaults) == keys.publicKey)
        #expect(TunnelSettings.relays(defaults).map(\.absoluteString) == ["wss://mine.example"])
    }

    /// Half a key in the old field is not carried over as a bridge, and with the switch on the
    /// public list is what is asked for — a refusal while it is empty, never a quiet direct route.
    @Test("a mistyped old address is not a bridge, and still no direct route")
    func aMistypedOldAddress() throws {
        let defaults = try fresh()
        defaults.set(true, forKey: TunnelSettings.enabledKey)
        defaults.set(String(try NostrKeypair.generate().npub.dropLast(4)), forKey: TunnelSettings.addressKey)
        #expect(TunnelSettings.customBridges(defaults).isEmpty)
        #expect(TunnelSettings.bridgeKey(defaults) == nil)
        #expect(TunnelSettings.asksForBridge(defaults))
    }

    @Test("several bridges of one's own, and switching between them")
    func severalOwnBridges() throws {
        let defaults = try fresh()
        let home = try #require(TunnelSettings.saveCustom(name: "Home", address: try NostrKeypair.generate().npub,
                                                          relays: "", defaults))
        let work = try #require(TunnelSettings.saveCustom(name: "Work", address: try NostrKeypair.generate().npub,
                                                          relays: "wss://work.example", defaults))
        #expect(TunnelSettings.customBridges(defaults).map(\.name) == ["Home", "Work"])
        #expect(home.relays == TunnelSettings.defaultRelays, "no relays typed means the defaults")

        TunnelSettings.choose(work, source: .custom, defaults)
        #expect(TunnelSettings.bridgeKey(defaults) == work.bridgeKey)
        TunnelSettings.choose(home, source: .custom, defaults)
        #expect(TunnelSettings.bridgeKey(defaults) == home.bridgeKey)
    }

    @Test("an address that is not a key is not saved")
    func aBadAddressIsNotSaved() throws {
        let defaults = try fresh()
        #expect(TunnelSettings.saveCustom(name: "x", address: "npub1nope", relays: "", defaults) == nil)
        #expect(TunnelSettings.customBridges(defaults).isEmpty)
    }

    @Test("editing the bridge in use keeps it in use, with its new address")
    func editingTheOneInUse() throws {
        let defaults = try fresh()
        let bridge = try #require(TunnelSettings.saveCustom(name: "Home", address: try NostrKeypair.generate().npub,
                                                            relays: "", defaults))
        TunnelSettings.choose(bridge, source: .custom, defaults)
        let moved = try NostrKeypair.generate()
        TunnelSettings.saveCustom(name: "Home", address: moved.npub, relays: "", id: bridge.id, defaults)
        #expect(TunnelSettings.customBridges(defaults).count == 1)
        #expect(TunnelSettings.bridgeKey(defaults) == moved.publicKey)
    }

    /// Deleting the bridge in use does not slide the next one into its place: a different bridge is
    /// a decision, and the person makes it.
    @Test("deleting the bridge in use leaves none of one's own in use")
    func deletingTheOneInUse() throws {
        let defaults = try fresh()
        let home = try #require(TunnelSettings.saveCustom(name: "Home", address: try NostrKeypair.generate().npub,
                                                          relays: "", defaults))
        TunnelSettings.saveCustom(name: "Work", address: try NostrKeypair.generate().npub, relays: "", defaults)
        TunnelSettings.choose(home, source: .custom, defaults)
        TunnelSettings.removeCustom(id: home.id, defaults)
        #expect(TunnelSettings.customBridges(defaults).map(\.name) == ["Work"])
        #expect(TunnelSettings.bridgeKey(defaults) != home.bridgeKey)
    }

    /// A public bridge that leaves the list stays the one in use: swapping in another behind the
    /// person's back is exactly what must not happen.
    @Test("a chosen public bridge that leaves the list stays chosen")
    func aDelistedBridgeStaysChosen() throws {
        let defaults = try fresh()
        let gone = try entry("gone")
        try list([gone, try entry("other")], into: defaults)
        TunnelSettings.choose(gone, source: .publicList, defaults)
        try list([try entry("other")], into: defaults)
        #expect(TunnelSettings.chosenBridge(defaults) == gone)
    }

    /// A choice of one kind is no answer for the other: going from "my own" back to the public list
    /// does not reuse my own bridge as if it were public.
    @Test("the chosen bridge belongs to the kind it was chosen in")
    func choicesDoNotCrossKinds() throws {
        let defaults = try fresh()
        let mine = try #require(TunnelSettings.saveCustom(name: "Home", address: try NostrKeypair.generate().npub,
                                                          relays: "", defaults))
        TunnelSettings.choose(mine, source: .custom, defaults)
        let listed = try entry("listed")
        try list([listed], into: defaults)
        defaults.set(TunnelSettings.Source.publicList.rawValue, forKey: TunnelSettings.sourceKey)
        #expect(TunnelSettings.chosenBridge(defaults) == listed)
    }

    /// Leaving the Connection screen rebuilds the session only when the connection would really be
    /// different. Tearing one down to build it again identically is a spinner for nothing.
    @Test("only a change of bridge or switch asks for a reconnect")
    func onlyAChangeThatMattersAsksForAReconnect() throws {
        let defaults = try fresh()
        defaults.set(true, forKey: TunnelSettings.enabledKey)
        let home = try #require(TunnelSettings.saveCustom(name: "Home", address: try NostrKeypair.generate().npub,
                                                          relays: "", defaults))
        TunnelSettings.choose(home, source: .custom, defaults)
        let before = TunnelSettings.snapshot(defaults)

        // Renamed: the same bridge, the same connection.
        TunnelSettings.saveCustom(name: "Home, renamed", address: home.npub, relays: "", id: home.id, defaults)
        #expect(TunnelSettings.snapshot(defaults) == before)

        let work = try #require(TunnelSettings.saveCustom(name: "Work", address: try NostrKeypair.generate().npub,
                                                          relays: "", defaults))
        TunnelSettings.choose(work, source: .custom, defaults)
        #expect(TunnelSettings.snapshot(defaults) != before)
    }

    // MARK: - The public list

    @Test("an unusable or duplicate entry is dropped, an unknown version refused whole")
    func listParsing() throws {
        let good = try NostrKeypair.generate().npub
        let json = """
        {"version": 1, "bridges": [
          {"id": "a", "name": "A", "npub": "\(good)", "relays": ["wss://r.example"], "homeservers": "*"},
          {"id": "a", "name": "A again", "npub": "\(good)", "relays": ["wss://r.example"]},
          {"id": "b", "name": "B", "npub": "npub1nope", "relays": ["wss://r.example"]},
          {"id": "c", "name": "C", "npub": "\(good)", "relays": ["https://not-a-relay.example"]},
          {"id": "d", "name": "D", "npub": "\(good)", "relays": ["wss://r.example"], "homeservers": ["matrix.org"]}
        ]}
        """
        let list = try #require(PublicBridgeList.parse(Data(json.utf8)))
        #expect(list.bridges.map(\.id) == ["a", "d"])
        #expect(list.bridges[0].homeservers == nil)
        #expect(list.bridges[1].homeservers == ["matrix.org"])

        #expect(PublicBridgeList.parse(Data(#"{"version": 2, "bridges": []}"#.utf8)) == nil)
        #expect(PublicBridgeList.parse(Data("not json".utf8)) == nil)
    }

    @Test("the list is downloaded at most once a day, and a failed or empty download changes nothing")
    func listRefresh() async throws {
        let defaults = try fresh()
        let bridge = try entry("listed")
        let good = try JSONEncoder().encode(PublicBridgeList(bridges: [bridge]))
        let start = Date()

        #expect(await PublicBridges.refresh(defaults: defaults, now: start) { _ in throw URLError(.notConnectedToInternet) } == false)
        #expect(PublicBridges.current(defaults).isEmpty)

        #expect(await PublicBridges.refresh(defaults: defaults, now: start) { _ in good })
        #expect(PublicBridges.current(defaults) == [bridge])

        // Within the day: not asked again.
        #expect(await PublicBridges.refresh(defaults: defaults, now: start.addingTimeInterval(3600)) { _ in
            Issue.record("downloaded twice in a day")
            return good
        } == false)

        // A list emptied by mistake does not take away the bridges somebody may be using.
        let empty = try JSONEncoder().encode(PublicBridgeList(bridges: []))
        #expect(await PublicBridges.refresh(defaults: defaults, now: start.addingTimeInterval(2 * 86_400)) { _ in empty } == false)
        #expect(PublicBridges.current(defaults) == [bridge])
    }

    @Test("the second source is tried when the first is blocked")
    func mirrorFallback() async throws {
        let defaults = try fresh()
        let good = try JSONEncoder().encode(PublicBridgeList(bridges: [try entry("listed")]))
        let refreshed = await PublicBridges.refresh(defaults: defaults) { url in
            if url.host() == "raw.githubusercontent.com" { throw URLError(.cannotConnectToHost) }
            return good
        }
        #expect(refreshed)
    }

    @Test("the snapshot built into the app is a list this build can read")
    func bundledSnapshotParses() {
        // Empty until the repository has its first bridge — but always readable.
        #expect(PublicBridges.bundled.version == PublicBridgeList.formatVersion)
    }
}
