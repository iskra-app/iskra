import Testing
import Foundation
import MatrixRustSDK
@testable import IskraCore

/// What gets written down as a session's homeserver, and how an old mistake in it is repaired.
///
/// The bridge's first protocol stood a listener of this app's own in for the homeserver, at
/// `http://127.0.0.1:<port>` on a port handed out afresh every launch — and before the app learnt
/// never to write that down, some records were saved with it. Read back, they dial a port that
/// closed when the app quit, and the app says there is no network. That protocol is gone; the
/// bridge is now a proxy and the client always holds the real address. What stays is the repair.
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

    /// The address is written down as the SDK has it: with the bridge a proxy, that is the real one.
    @Test func theAddressIsKeptExactly() {
        let stored = StoredSession(sessionID: "abc", session: session(homeserver: "https://example.org"))
        #expect(stored.homeserverURL == "https://example.org")
    }

    /// A record from the listener's days is recognised as one, which is what makes `restoreClient`
    /// look the server up again by name.
    @Test func anOldListenerRecordIsRecognised() {
        let stored = StoredSession(sessionID: "abc", session: session(homeserver: "http://127.0.0.1:61337"))
        #expect(TunnelSettings.isOurListener(stored.homeserverURL))
    }

    /// Our listeners only ever spoke `http`. A loopback `https` address is a real server behind
    /// real TLS — the blind-route tests' homeserver — and must not be "repaired".
    @Test(arguments: [
        ("http://127.0.0.1:61337", true),
        ("http://localhost:8080", true),
        ("https://127.0.0.1:8443", false),
        ("https://matrix.org", false),
        ("", false)
    ])
    func ourListenerIsPlainHTTPOnLoopback(address: String, expected: Bool) {
        #expect(TunnelSettings.isOurListener(address) == expected)
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
