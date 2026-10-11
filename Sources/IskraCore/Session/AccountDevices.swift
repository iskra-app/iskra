import Foundation

/// One session signed into this account — a row on the Devices screen.
public struct AccountDevice: Identifiable, Sendable, Equatable {
    public let id: String
    /// What the session calls itself, as the homeserver has it. Nil for a session that never said.
    public let name: String?
    public let lastSeenIP: String?
    public let lastSeenAt: Date?
    /// This device — the session the app is running.
    public let isCurrent: Bool

    public init(id: String, name: String?, lastSeenIP: String?, lastSeenAt: Date?, isCurrent: Bool) {
        self.id = id
        self.name = name
        self.lastSeenIP = lastSeenIP
        self.lastSeenAt = lastSeenAt
        self.isCurrent = isCurrent
    }

    /// The device, as a person would name it: "iPhone 16 Pro", "Firefox on Linux". Telegram puts
    /// the hardware first and the app under it, and so does this — see `DeviceName`.
    public var title: String { DeviceName(name).title ?? name ?? id }

    /// The app and the system under the title, where the name carries them: "Iskra 1.0 · iOS 26.0".
    public var detail: String? { DeviceName(name).detail }

    public var platform: DevicePlatform { DevicePlatform(name: name) }
}

/// What a session's name says it runs on — for the icon beside it.
public enum DevicePlatform: Sendable, Equatable {
    case iPhone, iPad, mac, android, web, desktop, unknown

    init(name: String?) {
        let name = (name ?? "").lowercased()
        func has(_ words: String...) -> Bool { words.contains { name.contains($0) } }

        if has("iphone") { self = .iPhone }
        else if has("ipad") { self = .iPad }
        else if has("android") { self = .android }
        else if has("firefox", "chrome", "safari", "edge", "browser", " web") { self = .web }
        else if has("macbook", "imac", "mac mini", "mac studio", "macos", "mac pro") { self = .mac }
        else if has("windows", "linux") { self = .desktop }
        else if has("ios") { self = .iPhone }
        else { self = .unknown }
    }
}

/// A session name taken apart into a title and a line under it.
///
/// Three shapes are common and understood; anything else is shown whole as the title, which is
/// always true even when it is not pretty.
///
/// - `Iskra/1.0 (iPhone 16 Pro; iOS 26.0)` — the User-Agent shape, which is what this app sends
///   (`DeviceDescription`) and what a parser on the far side turns into a name.
/// - `Element X iOS: iPhone`, `Element Web: Firefox on Linux` — "app: device", Element's.
/// - anything else — the name as it is.
struct DeviceName {
    let title: String?
    let detail: String?

    init(_ name: String?) {
        guard let name = name?.trimmingCharacters(in: .whitespaces), !name.isEmpty else {
            title = nil
            detail = nil
            return
        }

        // App/Version (Model; System)
        if let open = name.firstIndex(of: "("), name.hasSuffix(")"),
           let slash = name[..<open].firstIndex(of: "/") {
            let app = name[..<slash].trimmingCharacters(in: .whitespaces)
            let version = name[name.index(after: slash)..<open].trimmingCharacters(in: .whitespaces)
            let inside = name[name.index(after: open)..<name.index(before: name.endIndex)]
            let parts = inside.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }

            if let model = parts.first, !model.isEmpty {
                title = model
                let appLine = [app, version].filter { !$0.isEmpty }.joined(separator: " ")
                detail = ([appLine] + parts.dropFirst()).filter { !$0.isEmpty }.joined(separator: " · ")
                return
            }
        }

        // App: Device
        if let colon = name.range(of: ": ") {
            let app = name[..<colon.lowerBound].trimmingCharacters(in: .whitespaces)
            let device = name[colon.upperBound...].trimmingCharacters(in: .whitespaces)
            if !app.isEmpty, !device.isEmpty {
                title = device
                detail = app
                return
            }
        }

        title = name
        detail = nil
    }
}

/// Why a session could not be ended, in the terms the screen acts on.
public enum AccountDevicesError: Error, Sendable, Equatable {
    /// The server wants the account's password before it ends a session — Matrix's
    /// User-Interactive Auth. The screen asks for it and tries again.
    case needsPassword
    /// It was asked for, and it was not the password.
    case wrongPassword
    /// Sessions on this account are ended on the server's own page, not through the API — every
    /// account signed in through OAuth, which on matrix.org today is every new one: there
    /// `DELETE /devices` answers 404, because the endpoint does not exist any more. The URL is the
    /// page, when the server has one to name.
    case managedByServer(URL?)
    /// The server could not be reached the way the app reaches it, or said something else.
    case failed
}

/// The account's sessions: the list, and ending them — the Devices screen's model.
///
/// **Why this is the app's own request, and what that costs.** The Rust SDK has `devices()` and
/// `delete_devices()`; the FFI exports neither (see `ROADMAP.md`, the session list). So the list is
/// fetched here, with two rules that make it safe to do:
///
/// - **The request goes the way the SDK's go.** `send` is `AuthenticationService.send`, which hands
///   it to the same listener — the bridge, when the bridge is on — that carries every SDK request.
///   An app that went direct for this one call would be telling the homeserver, from this device's
///   own address, exactly what the bridge was switched on to hide.
/// - **The token is borrowed for one request and never kept.** Read from the SDK's session at the
///   moment of sending, put in one header, and gone with the request. Nothing logs it — not the
///   request, not the response.
public struct AccountDevices: Sendable {
    /// Sends one request to the homeserver with the account's token on it — see `UserSession`.
    let send: @Sendable (ProxiedRequest) async throws -> ProxiedResponse
    let userID: String
    let currentDeviceID: String
    /// The server's own page for ending a session (nil device ID: the list of them), for an account
    /// whose sessions are the server's to manage.
    let serverPage: @Sendable (String?) async -> URL?
    /// The account was signed in through OAuth, so its sessions are ended on the server's page.
    public let isManagedByServer: Bool

    public init(userID: String,
                currentDeviceID: String,
                isManagedByServer: Bool,
                send: @escaping @Sendable (ProxiedRequest) async throws -> ProxiedResponse,
                serverPage: @escaping @Sendable (String?) async -> URL?) {
        self.userID = userID
        self.currentDeviceID = currentDeviceID
        self.isManagedByServer = isManagedByServer
        self.send = send
        self.serverPage = serverPage
    }

    /// Every session on the account, this one first and the rest by how recently they were seen —
    /// Telegram's order.
    public func list() async throws -> [AccountDevice] {
        let response = try await send(ProxiedRequest(method: "GET", target: "/_matrix/client/v3/devices"))
        guard response.status == 200 else { throw AccountDevicesError.failed }
        return try Self.devices(from: response.body, current: currentDeviceID)
    }

    /// Ends these sessions — signs those devices out of the account.
    ///
    /// Asked first without a password, because some servers do not want one; the answer then says
    /// whether it does (`needsPassword`), and the screen asks and calls again with it.
    public func end(_ deviceIDs: [String], password: String? = nil) async throws {
        let others = deviceIDs.filter { $0 != currentDeviceID }
        guard !others.isEmpty else { return }

        if isManagedByServer {
            throw AccountDevicesError.managedByServer(await serverPage(others.count == 1 ? others[0] : nil))
        }

        var body: [String: Any] = ["devices": others]
        if let password {
            body["auth"] = ["type": "m.login.password",
                            "identifier": ["type": "m.id.user", "user": userID],
                            "password": password,
                            "session": try await authSession(for: others) as Any]
        }

        let response = try await send(Self.post("/_matrix/client/v3/delete_devices", body))
        switch Self.outcome(of: response, withPassword: password != nil) {
        case .done:
            return
        case let .refused(error):
            if case .managedByServer = error {
                throw AccountDevicesError.managedByServer(await serverPage(others.count == 1 ? others[0] : nil))
            }
            throw error
        }
    }

    /// The UIA session the server opened for this deletion — asked for by making the request once
    /// without auth, which is how the protocol hands one out.
    private func authSession(for deviceIDs: [String]) async throws -> String? {
        let response = try await send(Self.post("/_matrix/client/v3/delete_devices", ["devices": deviceIDs]))
        let json = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any]
        return json?["session"] as? String
    }

    private static func post(_ target: String, _ body: [String: Any]) -> ProxiedRequest {
        ProxiedRequest(method: "POST", target: target,
                       headers: ["Content-Type": "application/json"],
                       body: (try? JSONSerialization.data(withJSONObject: body)) ?? Data())
    }

    // MARK: - Reading the answers (tested directly)

    enum Outcome: Equatable {
        case done
        case refused(AccountDevicesError)
    }

    /// What a delete answered, in the screen's terms.
    static func outcome(of response: ProxiedResponse, withPassword: Bool) -> Outcome {
        if (200..<300).contains(response.status) { return .done }

        let json = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any]
        let errcode = json?["errcode"] as? String

        // The endpoint is not there at all — a server whose sessions live behind its own page.
        if response.status == 404 || errcode == "M_UNRECOGNIZED" {
            return .refused(.managedByServer(nil))
        }

        if response.status == 401 {
            if withPassword, errcode == "M_FORBIDDEN" { return .refused(.wrongPassword) }

            let flows = (json?["flows"] as? [[String: Any]]) ?? []
            let stages = flows.flatMap { ($0["stages"] as? [String]) ?? [] }
            if stages.contains("m.login.password") {
                return .refused(withPassword ? .wrongPassword : .needsPassword)
            }
            // Asked for something this app cannot give in place — SSO, a web page.
            return .refused(.managedByServer(nil))
        }

        return .refused(.failed)
    }

    /// The list, as the server sent it.
    static func devices(from body: Data, current: String) throws -> [AccountDevice] {
        guard let json = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              let entries = json["devices"] as? [[String: Any]] else {
            throw AccountDevicesError.failed
        }

        let devices = entries.compactMap { entry -> AccountDevice? in
            guard let id = entry["device_id"] as? String else { return nil }
            let seen = (entry["last_seen_ts"] as? NSNumber).map {
                Date(timeIntervalSince1970: $0.doubleValue / 1000)
            }
            let name = (entry["display_name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return AccountDevice(id: id,
                                 name: name,
                                 lastSeenIP: entry["last_seen_ip"] as? String,
                                 lastSeenAt: seen,
                                 isCurrent: id == current)
        }

        return devices.sorted { lhs, rhs in
            if lhs.isCurrent != rhs.isCurrent { return lhs.isCurrent }
            return (lhs.lastSeenAt ?? .distantPast) > (rhs.lastSeenAt ?? .distantPast)
        }
    }
}
