import Foundation
import Synchronization
import Testing
@testable import IskraCore

/// Settings → Devices: the account's sessions, read from the server the way the SDK reaches it,
/// and ended — with the account's password where the server wants it, on the server's own page
/// where the sessions are its to end.
@Suite("Account devices")
struct AccountDevicesTests {
    private func json(_ object: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    @Test("this device first, then the rest by how recently they were seen")
    func order() throws {
        let body = json(["devices": [
            ["device_id": "OLD", "display_name": "Element Web: Firefox on Linux", "last_seen_ts": 1_000],
            ["device_id": "ME", "display_name": "Iskra/1.0 (iPhone 16 Pro; iOS 26.0)", "last_seen_ts": 500],
            ["device_id": "NEW", "last_seen_ts": 9_000, "last_seen_ip": "198.51.100.7"],
        ]])

        let devices = try AccountDevices.devices(from: body, current: "ME")
        #expect(devices.map(\.id) == ["ME", "NEW", "OLD"])
        #expect(devices[0].isCurrent)
        #expect(devices[1].lastSeenIP == "198.51.100.7")
        #expect(devices[1].lastSeenAt == Date(timeIntervalSince1970: 9))
    }

    @Test("a User-Agent name is the hardware over the app and the system")
    func userAgentName() {
        let device = AccountDevice(id: "A", name: "Iskra/1.0 (iPhone 16 Pro; iOS 26.0)",
                                   lastSeenIP: nil, lastSeenAt: nil, isCurrent: true)
        #expect(device.title == "iPhone 16 Pro")
        #expect(device.detail == "Iskra 1.0 · iOS 26.0")
        #expect(device.platform == .iPhone)
    }

    @Test("an \"app: device\" name is the device over the app")
    func elementName() {
        let device = AccountDevice(id: "B", name: "Element Web: Firefox on Linux",
                                   lastSeenIP: nil, lastSeenAt: nil, isCurrent: false)
        #expect(device.title == "Firefox on Linux")
        #expect(device.detail == "Element Web")
        #expect(device.platform == .web)
    }

    @Test("a name nobody parses is shown whole, and no name is the device ID")
    func otherNames() {
        let named = AccountDevice(id: "C", name: "my laptop", lastSeenIP: nil, lastSeenAt: nil, isCurrent: false)
        #expect(named.title == "my laptop")
        #expect(named.detail == nil)

        let unnamed = AccountDevice(id: "DEVICEID", name: nil, lastSeenIP: nil, lastSeenAt: nil, isCurrent: false)
        #expect(unnamed.title == "DEVICEID")
        #expect(unnamed.platform == .unknown)
    }

    @Test("what a delete answered, in the screen's terms")
    func outcomes() {
        func response(_ status: Int, _ body: Any = [String: Any]()) -> ProxiedResponse {
            ProxiedResponse(status: status, body: json(body))
        }
        let passwordFlow: [String: Any] = ["session": "s", "flows": [["stages": ["m.login.password"]]]]
        let ssoFlow: [String: Any] = ["session": "s", "flows": [["stages": ["m.login.sso"]]]]

        #expect(AccountDevices.outcome(of: response(200), withPassword: false) == .done)
        #expect(AccountDevices.outcome(of: response(401, passwordFlow), withPassword: false) == .refused(.needsPassword))
        #expect(AccountDevices.outcome(of: response(401, ["errcode": "M_FORBIDDEN"]), withPassword: true)
                == .refused(.wrongPassword))
        #expect(AccountDevices.outcome(of: response(401, ssoFlow), withPassword: false) == .refused(.managedByServer(nil)))
        #expect(AccountDevices.outcome(of: response(404, ["errcode": "M_UNRECOGNIZED"]), withPassword: false)
                == .refused(.managedByServer(nil)))
        #expect(AccountDevices.outcome(of: response(500), withPassword: false) == .refused(.failed))
    }

    @Test("ending asks without a password, then with it, in the same auth session")
    func passwordFlow() async throws {
        let sent = Mutex<[ProxiedRequest]>([])
        let source = AccountDevices(
            userID: "@me:example.org",
            currentDeviceID: "ME",
            isManagedByServer: false,
            send: { request in
                sent.withLock { $0.append(request) }
                let body = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any]
                if body?["auth"] == nil {
                    return ProxiedResponse(status: 401, body: try JSONSerialization.data(withJSONObject:
                        ["session": "uia-1", "flows": [["stages": ["m.login.password"]]]]))
                }
                return ProxiedResponse(status: 200, body: Data("{}".utf8))
            },
            serverPage: { _ in nil })

        await #expect(throws: AccountDevicesError.needsPassword) {
            try await source.end(["OTHER"])
        }

        try await source.end(["OTHER", "ME"], password: "hunter2")

        let last = try #require(sent.withLock { $0.last })
        let body = try #require(try JSONSerialization.jsonObject(with: last.body) as? [String: Any])
        // This device is never asked to end itself — that is signing out, and it lives elsewhere.
        #expect(body["devices"] as? [String] == ["OTHER"])
        let auth = try #require(body["auth"] as? [String: Any])
        #expect(auth["session"] as? String == "uia-1")
        #expect(auth["type"] as? String == "m.login.password")
    }

    @Test("an account signed in through the browser is sent to the server's page")
    func managedByServer() async {
        let page = URL(string: "https://account.example.org/sessions/OTHER")!
        let source = AccountDevices(userID: "@me:example.org", currentDeviceID: "ME", isManagedByServer: true,
                                    send: { _ in Issue.record("nothing should be sent"); return ProxiedResponse(status: 500) },
                                    serverPage: { id in id == "OTHER" ? page : nil })

        await #expect(throws: AccountDevicesError.managedByServer(page)) {
            try await source.end(["OTHER"])
        }
    }
}
