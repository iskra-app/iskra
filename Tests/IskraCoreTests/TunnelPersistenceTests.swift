import Testing
import Foundation
import MatrixRustSDK
@testable import IskraCore

/// The rule these pin is worth stating plainly, because breaking it bricks the app one launch
/// later and blames the network for it.
///
/// With the bridge switch on, the SDK's homeserver is `http://127.0.0.1:<port>` — a listener this
/// process raised, on a port the system hands out afresh every launch. Everything the SDK reports
/// about itself carries that address, including the session it asks us to save. Written into the
/// Keychain, it is read back next launch as the address of a port that closed when the app quit:
/// the app dials itself, finds nothing, and says there is no network.
///
/// `.serialized` because the register is process-wide, which is the honest shape for a thing there
/// is only ever one of — see `TunnelSettings.listenerStandsIn(for:)`.
@Suite(.serialized)
struct TunnelPersistenceTests {
    private func session(homeserver: String) -> Session {
        Session(accessToken: "token",
                refreshToken: nil,
                userId: "@ann:matrix.org",
                deviceId: "DEVICE",
                homeserverUrl: homeserver,
                oauthData: nil,
                slidingSyncVersion: .native)
    }

    @Test func loopbackIsNeverWrittenDown() {
        TunnelSettings.listenerStandsIn(for: URL(string: "https://matrix-client.matrix.org")!)
        defer { TunnelSettings.listenerStoppedStandingIn() }

        let stored = StoredSession(sessionID: "abc", session: session(homeserver: "http://127.0.0.1:61337"))
        #expect(stored.homeserverURL == "https://matrix-client.matrix.org")
    }

    @Test func aRealAddressIsKeptExactly() {
        TunnelSettings.listenerStandsIn(for: URL(string: "https://matrix-client.matrix.org")!)
        defer { TunnelSettings.listenerStoppedStandingIn() }

        let stored = StoredSession(sessionID: "abc", session: session(homeserver: "https://example.org"))
        #expect(stored.homeserverURL == "https://example.org")
    }

    /// With the switch off there is nothing to substitute. The value goes through unchanged rather
    /// than being invented — and the restore path recognises it and repairs it, which is the only
    /// honest answer once the record is already poisoned.
    @Test func withNoListenerTheAddressIsLeftAlone() {
        TunnelSettings.listenerStoppedStandingIn()
        let stored = StoredSession(sessionID: "abc", session: session(homeserver: "http://127.0.0.1:61337"))
        #expect(stored.homeserverURL == "http://127.0.0.1:61337")
        #expect(TunnelSettings.isLoopback(stored.homeserverURL))
    }

    @Test(arguments: [
        ("http://127.0.0.1:61337", true),
        ("http://localhost:8080", true),
        ("https://matrix.org", false),
        ("https://127.0.0.1.example.org", false),
        ("", false)
    ])
    func loopbackIsRecognised(address: String, expected: Bool) {
        #expect(TunnelSettings.isLoopback(address) == expected)
    }

    /// How a poisoned record is recovered: the user ID says which server the session belongs to,
    /// and it is the only part of the record the mistake could not corrupt.
    @Test func theServerNameSurvivesInTheUserID() {
        let stored = StoredSession(sessionID: "abc", session: session(homeserver: "http://127.0.0.1:1"))
        #expect(stored.serverName == "matrix.org")
    }

    @Test func repointingKeepsEverythingElse() {
        let stored = StoredSession(sessionID: "abc", session: session(homeserver: "https://example.org"))
        let moved = stored.with(homeserverURL: "https://matrix.org")
        #expect(moved.homeserverURL == "https://matrix.org")
        #expect(moved.sessionID == stored.sessionID)
        #expect(moved.accessToken == stored.accessToken)
        #expect(moved.deviceID == stored.deviceID)
    }
}
