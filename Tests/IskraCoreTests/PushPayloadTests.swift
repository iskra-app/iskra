import Testing
import Foundation
@testable import IskraCore

/// The shell of the notification: written once at registration, kept by the homeserver, and handed
/// to the gateway with every push the account ever receives.
///
/// It is two keys long and both are load-bearing, and the failure when one is missing is *silence*
/// — the gateway answers `200`, Apple accepts the push, and nothing appears on the phone. Nothing
/// in the app logs, because nothing in the app ran: the notification service extension is only
/// woken for a push that is already a notification. That is the whole reason this is pinned here
/// rather than trusted to stay right.
@Suite("Default push payload")
struct PushPayloadTests {
    private func payload() throws -> [String: Any] {
        let json = try #require(PushRegistration.defaultPayload())
        let object = try JSONSerialization.jsonObject(with: try #require(json.data(using: .utf8)))
        return try #require(object as? [String: Any])
    }

    @Test("the extension is allowed to run")
    func mutableContentIsSet() throws {
        let aps = try #require(try payload()["aps"] as? [String: Any])

        // Without this iOS never wakes the extension, and a message arrives as the server's
        // fallback text at best.
        #expect(aps["mutable-content"] as? Int == 1)
    }

    @Test("it is a notification, not a silent push")
    func theAlertHasBothHalves() throws {
        let aps = try #require(try payload()["aps"] as? [String: Any])
        let alert = try #require(aps["alert"] as? [String: Any])

        // Both halves, not one: an alert with only a body does not reliably wake the extension.
        #expect((alert["title"] as? String)?.isEmpty == false)
        #expect((alert["body"] as? String)?.isEmpty == false)
    }

    @Test("it says nothing about any particular message")
    func thePayloadCarriesNoContent() throws {
        let json = try #require(PushRegistration.defaultPayload())

        // One sentence reused for every push, so anything specific in it would be a fact about one
        // message shown above another. It is also the half of a push that Apple can read.
        #expect(!json.contains("room"))
        #expect(!json.contains("event"))
        #expect(!json.contains("sender"))
    }

    /// Two people on one phone can be in the same room, so a push has to say whose it is or the
    /// extension is left guessing which store to open. It says so with the account's random session
    /// ID — never the Matrix ID, which would tell the gateway and Apple who is signed in here.
    @Test("it says whose push it is, without saying who that is")
    func thePayloadNamesTheAccount() throws {
        let json = try #require(PushRegistration.defaultPayload(accountID: "3F2A-random"))
        let object = try JSONSerialization.jsonObject(with: try #require(json.data(using: .utf8)))
        let payload = try #require(object as? [String: Any])

        #expect(payload[PushRegistration.accountKey] as? String == "3F2A-random")
        #expect(!json.contains("@"))
    }
}
