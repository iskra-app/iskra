import Foundation
import Synchronization

/// A homeserver that lives inside the app, for walking the sign-in and registration screens
/// without a real one.
///
/// Not a stand-in for `AuthenticationService` — the *server* is what is fake, and nothing else.
/// It is an `HTTPUpstream`, so it sits behind the same `LocalHTTPProxy` the bridge uses, on
/// `127.0.0.1`, and the real SDK talks to it over real HTTP: discovery, `/versions`, the login
/// flows, the OIDC dance, whoami. Every line of `AuthenticationService` and `SignInModel` runs
/// exactly as it would against matrix.org, and the flow ends in a real `UserSession` — which a
/// fake *service* could never hand back, because a session is built around a live `Client`.
///
/// The browser half is real too. OIDC's authorize endpoint answers with a small HTML page, the
/// page's button redirects to `moscow.swag.iskra:/oauth-callback`, and `ASWebAuthenticationSession`
/// catches it the way it catches Matrix Authentication Service. That is the one piece of the
/// registration flow nobody can test from `swift test`, and here it can be tapped through.
///
/// What it deliberately is not: a Matrix server. Past whoami it answers only what the app needs to
/// settle on an empty account — through the first-run screen to its recovery code, and into an
/// empty chat list — and everything else gets `M_UNRECOGNIZED`, which is what a real server says
/// too, and which `unanswered` keeps a list of.
///
/// No cryptography here is anyone's; keys are accepted and forgotten. Nothing leaves loopback.
public final class SignInMockServer: HTTPUpstream {
    public struct Configuration: Sendable {
        /// What goes after the colon in every user ID it mints.
        public var serverName: String
        /// Username → password. Password sign-in and OIDC sign-in both check against these.
        public var accounts: [String: String]
        public var offersPassword: Bool
        /// Old-style `m.login.sso`: a redirect to a page, a login token back.
        public var offersLegacySSO: Bool
        /// OIDC through `/auth_metadata`, the way Matrix Authentication Service does it.
        public var offersOAuth: Bool
        /// Whether OIDC advertises `prompt=create`. Only meaningful with `offersOAuth`.
        public var offersRegistration: Bool
        /// Added to every answer, so that a spinner can be looked at.
        public var latency: Duration

        public init(serverName: String = "iskra.test",
                    accounts: [String: String] = ["alice": "password"],
                    offersPassword: Bool = true,
                    offersLegacySSO: Bool = false,
                    offersOAuth: Bool = true,
                    offersRegistration: Bool = true,
                    latency: Duration = .zero) {
            self.serverName = serverName
            self.accounts = accounts
            self.offersPassword = offersPassword
            self.offersLegacySSO = offersLegacySSO
            self.offersOAuth = offersOAuth
            self.offersRegistration = offersRegistration
            self.latency = latency
        }
    }

    private struct State {
        var accounts: [String: String]
        /// Access token → user ID.
        var tokens: [String: String] = [:]
        /// One-time codes — OIDC authorization codes and legacy login tokens alike — → user ID.
        var codes: [String: String] = [:]
        /// Access token → device ID, for whoami. OIDC puts the device in the scope.
        var devices: [String: String] = [:]
        /// Authorization code → the device ID the client asked for in its scope.
        var codeDevices: [String: String] = [:]
        var requests: [ProxiedRequest] = []
        var unanswered: [ProxiedRequest] = []

        /// Account data by request path, as the client last wrote it.
        var accountData: [String: Data] = [:]
        /// User → device ID → the device's signed keys.
        var deviceKeys: [String: [String: Data]] = [:]
        /// User → `master_key` / `self_signing_key` / `user_signing_key` → the key.
        var crossSigning: [String: [String: Data]] = [:]
        /// Every backup version ever made, oldest first; the version number is the position plus one.
        var backups: [Data] = []

        /// Adds the signatures on a signed object to the stored copy of it. The object is named by
        /// its device ID, or, for a cross-signing key, by the public key itself.
        mutating func addSignatures(of object: [String: Any], owner: String, keyID: String) {
            guard let signatures = object["signatures"] as? [String: Any] else { return }

            func merged(_ data: Data) -> Data {
                guard var stored = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return data }
                var existing = stored["signatures"] as? [String: Any] ?? [:]
                for (signer, keys) in signatures {
                    var mine = existing[signer] as? [String: Any] ?? [:]
                    for (key, value) in keys as? [String: Any] ?? [:] { mine[key] = value }
                    existing[signer] = mine
                }
                stored["signatures"] = existing
                return (try? JSONSerialization.data(withJSONObject: stored)) ?? data
            }

            if let device = deviceKeys[owner]?[keyID] {
                deviceKeys[owner]?[keyID] = merged(device)
                return
            }
            for (kind, key) in crossSigning[owner] ?? [:] where String(decoding: key, as: UTF8.self).contains(keyID) {
                crossSigning[owner]?[kind] = merged(key)
            }
        }

        /// The answer to `/keys/query`, for the users asked about.
        func query(_ users: [String]) -> Data {
            var devices: [String: Any] = [:]
            var masters: [String: Any] = [:]
            var selfSigning: [String: Any] = [:]
            var userSigning: [String: Any] = [:]

            for user in users {
                var theirs: [String: Any] = [:]
                for (id, data) in deviceKeys[user] ?? [:] {
                    theirs[id] = try? JSONSerialization.jsonObject(with: data)
                }
                devices[user] = theirs

                let keys = crossSigning[user] ?? [:]
                masters[user] = keys["master_key"].flatMap { try? JSONSerialization.jsonObject(with: $0) }
                selfSigning[user] = keys["self_signing_key"].flatMap { try? JSONSerialization.jsonObject(with: $0) }
                userSigning[user] = keys["user_signing_key"].flatMap { try? JSONSerialization.jsonObject(with: $0) }
            }

            let answer: [String: Any] = [
                "device_keys": devices,
                "master_keys": masters,
                "self_signing_keys": selfSigning,
                "user_signing_keys": userSigning,
                "failures": [:] as [String: Any],
            ]
            return (try? JSONSerialization.data(withJSONObject: answer)) ?? Data("{}".utf8)
        }
    }

    public let configuration: Configuration
    private let state: Mutex<State>

    /// Where this server believes it lives: the listener's address, set once it has a port.
    /// Needed because OIDC metadata and redirects are absolute URLs.
    private let base = Mutex<String>("http://127.0.0.1")

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        self.state = Mutex(State(accounts: configuration.accounts))
    }

    /// Every request the SDK made, oldest first. What a test looks at to see which path ran.
    public var requests: [ProxiedRequest] { state.withLock { $0.requests } }

    /// Requests it had no answer for, and said `M_UNRECOGNIZED` to. Empty is the goal; when an SDK
    /// update starts asking for something new, this is where it shows up first.
    public var unanswered: [ProxiedRequest] { state.withLock { $0.unanswered } }

    /// Accounts as they are now, including any the registration page made.
    public var accounts: [String: String] { state.withLock { $0.accounts } }

    /// Brings the server up on loopback and returns the listener serving it, with the address to
    /// type into the sign-in field. Stop the listener to stop the server.
    public func start() async throws -> (proxy: LocalHTTPProxy, address: String) {
        let proxy = LocalHTTPProxy(upstream: self)
        let port = try await proxy.start()
        // So the app's own requests (`AccountDevices`) reach this server as the SDK's do.
        AuthenticationService.register(standalone: proxy, port: port)
        let address = "http://127.0.0.1:\(port)"
        base.withLock { $0 = address }
        return (proxy, address)
    }

    public func send(_ request: ProxiedRequest) async throws -> ProxiedResponse {
        state.withLock { $0.requests.append(request) }
        if configuration.latency > .zero {
            try? await Task.sleep(for: configuration.latency)
        }
        let (path, query) = Self.split(request.target)
        let response = path.hasPrefix("/_matrix/client/unstable/org.matrix.simplified_msc3575/sync")
            ? await sync(request, query: query)
            : route(request)
        if response == .unrecognized {
            state.withLock { $0.unanswered.append(request) }
        }
        return response
    }

    // MARK: - Routing

    private func route(_ request: ProxiedRequest) -> ProxiedResponse {
        let (path, query) = Self.split(request.target)
        let method = request.method.uppercased()

        switch (method, path) {
        case ("GET", "/.well-known/matrix/client"):
            return .json(["m.homeserver": ["base_url": base.withLock { $0 }]])

        case ("GET", "/_matrix/client/versions"):
            return .json([
                "versions": ["v1.1", "v1.5", "v1.11", "v1.12", "v1.13"],
                "unstable_features": ["org.matrix.simplified_msc3575": true],
            ])

        case ("GET", "/_matrix/client/v3/login"), ("GET", "/_matrix/client/r0/login"):
            return loginFlows()

        case ("POST", "/_matrix/client/v3/login"), ("POST", "/_matrix/client/r0/login"):
            return login(request.body)

        case ("GET", "/_matrix/client/v3/login/sso/redirect"),
             ("GET", "/_matrix/client/r0/login/sso/redirect"):
            guard configuration.offersLegacySSO else { return .unrecognized }
            return page(for: .legacySSO, query: query)

        case ("GET", "/_matrix/client/v1/auth_metadata"),
             ("GET", "/_matrix/client/unstable/org.matrix.msc2965/auth_metadata"):
            guard configuration.offersOAuth else { return .unrecognized }
            return authMetadata()

        case ("GET", "/_matrix/client/unstable/org.matrix.msc2965/auth_issuer"),
             ("GET", "/_matrix/client/v1/auth_issuer"):
            guard configuration.offersOAuth else { return .unrecognized }
            return .json(["issuer": base.withLock { $0 } + "/"])

        case ("GET", "/_mock/oauth/jwks"):
            return .json(["keys": [] as [Any]])

        case ("POST", "/_mock/oauth/register"):
            // Dynamic client registration: whoever asks gets an ID. Echo what they sent, because
            // the SDK checks that the redirect URIs it registered are the ones it got back.
            var client = (try? JSONSerialization.jsonObject(with: request.body) as? [String: Any]) ?? [:]
            client["client_id"] = "mock-client"
            return .json(client, status: 201)

        case ("GET", "/_mock/oauth/authorize"):
            return page(for: query["prompt"] == "create" ? .register : .signIn, query: query)

        case ("GET", "/_mock/oauth/approve"):
            return approve(query)

        case ("POST", "/_mock/oauth/token"):
            return token(Self.form(request.body))

        case ("POST", "/_mock/oauth/revoke"):
            return .json([:])

        case ("GET", "/_matrix/client/v3/account/whoami"), ("GET", "/_matrix/client/r0/account/whoami"):
            guard let token = Self.bearer(request),
                  let user = state.withLock({ $0.tokens[token] }) else { return .unknownToken }
            let device = state.withLock { $0.devices[token] } ?? "MOCKDEVICE"
            return .json(["user_id": user, "device_id": device, "is_guest": false])

        case ("POST", "/_matrix/client/v3/logout"), ("POST", "/_matrix/client/r0/logout"):
            if let token = Self.bearer(request) {
                state.withLock { _ = $0.tokens.removeValue(forKey: token) }
            }
            return .json([:])

        default:
            return afterSignIn(method: method, path: path, request: request)
        }
    }

    /// What an empty account needs so the app can sit on it without raising alarms.
    ///
    /// It is not enough to say "yes" to everything, and that was tried first. The SDK sets up
    /// cross-signing and turns on key backup the moment somebody signs in, and then *reads back*
    /// what it wrote: a key query that does not return the keys it just uploaded, or account data
    /// that is still 404 after a PUT, is an account whose encryption never took, and the first-run
    /// screen gives up on it. So this remembers exactly those three things — account data, the
    /// keys, and backup versions — and nothing about rooms, because there are none.
    private func afterSignIn(method: String, path: String, request: ProxiedRequest) -> ProxiedResponse {
        let user = Self.bearer(request).flatMap { token in state.withLock { $0.tokens[token] } }
        let json = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] ?? [:]

        // Account data, global and per room: the path is the key.
        if path.contains("/account_data/") {
            switch method {
            case "PUT":
                state.withLock { $0.accountData[path] = request.body }
                return .json([:])
            default:
                guard let stored = state.withLock({ $0.accountData[path] }) else { return .notFound }
                return .raw(stored)
            }
        }

        if path.hasSuffix("/keys/upload") {
            if let user, let device = json["device_keys"] as? [String: Any],
               let id = device["device_id"] as? String,
               let data = try? JSONSerialization.data(withJSONObject: device) {
                state.withLock { $0.deviceKeys[user, default: [:]][id] = data }
            }
            return .json(["one_time_key_counts": ["signed_curve25519": 50]])
        }

        if path.hasSuffix("/keys/device_signing/upload") {
            guard let user else { return .unknownToken }
            state.withLock { state in
                for kind in ["master_key", "self_signing_key", "user_signing_key"] {
                    if let key = json[kind], let data = try? JSONSerialization.data(withJSONObject: key) {
                        state.crossSigning[user, default: [:]][kind] = data
                    }
                }
            }
            return .json([:])
        }

        if path.hasSuffix("/keys/signatures/upload") {
            state.withLock { state in
                for (owner, objects) in json {
                    for (keyID, object) in objects as? [String: Any] ?? [:] {
                        state.addSignatures(of: object as? [String: Any] ?? [:], owner: owner, keyID: keyID)
                    }
                }
            }
            return .json(["failures": [:] as [String: Any]])
        }

        if path.hasSuffix("/keys/query") {
            let asked = (json["device_keys"] as? [String: Any])?.keys.map { $0 } ?? []
            return .raw(state.withLock { $0.query(asked) })
        }

        if path.hasSuffix("/keys/claim") {
            return .json(["one_time_keys": [:] as [String: Any], "failures": [:] as [String: Any]])
        }

        if path.hasSuffix("/room_keys/version") || path.contains("/room_keys/version/") {
            switch method {
            case "POST":
                let version = state.withLock { state -> String in
                    state.backups.append(request.body)
                    return String(state.backups.count)
                }
                return .json(["version": version])
            case "DELETE":
                return .json([:])
            case "PUT":
                return .json([:])
            default:
                guard let latest = state.withLock({ state in state.backups.last.map { ($0, state.backups.count) } }),
                      var backup = (try? JSONSerialization.jsonObject(with: latest.0)) as? [String: Any]
                else { return .notFound }
                backup["version"] = String(latest.1)
                backup["count"] = 0
                backup["etag"] = "0"
                return .json(backup)
            }
        }

        if path.contains("/room_keys/keys") {
            return .json(["count": 0, "etag": "0"])
        }

        if path.contains("/profile/") {
            return .json([:])
        }

        if path.hasSuffix("/pushrules/") || path.hasSuffix("/pushrules") {
            return .json(["global": [:] as [String: Any]])
        }

        if path.hasSuffix("/pushers/set") || path.contains("/sendToDevice/") {
            return .json([:])
        }

        if path.contains("/capabilities") {
            return .json(["capabilities": [:] as [String: Any]])
        }

        return .unrecognized
    }

    /// Sliding sync, for an account with no rooms in it.
    ///
    /// Every list the client asks for is answered with a count of nought, which is what tells the
    /// room list it has finished loading rather than not started. And a request that carries a
    /// position and a timeout is held for that timeout, capped: it is a long-poll with nothing to
    /// report, and answering it at once sends the SDK round in a loop as fast as loopback allows.
    private func sync(_ request: ProxiedRequest, query: [String: String]) async -> ProxiedResponse {
        if query["pos"] != nil, let timeout = query["timeout"].flatMap(Int.init), timeout > 0 {
            try? await Task.sleep(for: .milliseconds(min(timeout, 30_000)))
        }

        let json = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] ?? [:]
        var lists: [String: Any] = [:]
        for name in (json["lists"] as? [String: Any] ?? [:]).keys {
            lists[name] = ["count": 0]
        }
        return .json([
            "pos": String(Int(query["pos"] ?? "0").map { $0 + 1 } ?? 1),
            "lists": lists,
            "rooms": [:] as [String: Any],
            "extensions": [:] as [String: Any],
        ])
    }

    // MARK: - Password and legacy SSO

    private func loginFlows() -> ProxiedResponse {
        var flows: [[String: Any]] = []
        if configuration.offersPassword {
            flows.append(["type": "m.login.password"])
        }
        if configuration.offersLegacySSO {
            flows.append(["type": "m.login.sso", "identity_providers": [] as [Any]])
            flows.append(["type": "m.login.token"])
        }
        return .json(["flows": flows])
    }

    private func login(_ body: Data) -> ProxiedResponse {
        guard let request = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let type = request["type"] as? String else { return .badJSON }

        let user: String
        switch type {
        case "m.login.password" where configuration.offersPassword:
            let identifier = request["identifier"] as? [String: Any]
            let typed = (identifier?["user"] as? String) ?? (request["user"] as? String) ?? ""
            let name = localPart(of: typed)
            let password = request["password"] as? String
            guard let expected = state.withLock({ $0.accounts[name] }), expected == password else {
                return .forbidden
            }
            user = userID(for: name)

        case "m.login.token" where configuration.offersLegacySSO:
            guard let code = request["token"] as? String,
                  let owner = state.withLock({ $0.codes.removeValue(forKey: code) }) else {
                return .forbidden
            }
            user = owner

        default:
            return .error("M_UNKNOWN", "Unsupported login type", status: 400)
        }

        let device = (request["device_id"] as? String) ?? Self.mint(prefix: "MOCK", length: 6)
        let token = issueToken(for: user, device: device)
        return .json([
            "user_id": user,
            "access_token": token,
            "device_id": device,
            "home_server": configuration.serverName,
        ])
    }

    // MARK: - OIDC

    private func authMetadata() -> ProxiedResponse {
        let base = base.withLock { $0 }
        var prompts: [String] = []
        if configuration.offersRegistration { prompts.append("create") }
        return .json([
            "issuer": base + "/",
            "authorization_endpoint": base + "/_mock/oauth/authorize",
            "token_endpoint": base + "/_mock/oauth/token",
            "registration_endpoint": base + "/_mock/oauth/register",
            "revocation_endpoint": base + "/_mock/oauth/revoke",
            "jwks_uri": base + "/_mock/oauth/jwks",
            "account_management_uri": base + "/_mock/account",
            "response_types_supported": ["code"],
            "response_modes_supported": ["query", "fragment"],
            "grant_types_supported": ["authorization_code", "refresh_token"],
            "code_challenge_methods_supported": ["S256"],
            "token_endpoint_auth_methods_supported": ["none"],
            "prompt_values_supported": prompts,
        ])
    }

    /// The page's button lands here. Checks the password — or makes the account, when this came
    /// from the registration page — and sends the browser home with a one-time code.
    private func approve(_ query: [String: String]) -> ProxiedResponse {
        guard let redirect = query["redirect_uri"], !redirect.isEmpty else { return .badJSON }
        let name = localPart(of: query["username"] ?? "")
        let password = query["password"] ?? ""
        let flow = Page(rawValue: query["flow"] ?? "") ?? .signIn

        if name.isEmpty {
            return page(for: flow, query: query, problem: "Имя не может быть пустым.")
        }

        let accepted: Bool = state.withLock { state in
            switch flow {
            case .register:
                guard state.accounts[name] == nil else { return false }
                state.accounts[name] = password
                return true
            case .signIn, .legacySSO:
                return state.accounts[name] == password
            }
        }
        guard accepted else {
            let problem = flow == .register ? "Имя «\(name)» уже занято." : "Неверное имя или пароль."
            return page(for: flow, query: query, problem: problem)
        }

        let code = Self.mint(prefix: "code_", length: 16)
        let device = query["scope"].flatMap(Self.device(inScope:))
        state.withLock {
            $0.codes[code] = userID(for: name)
            if let device { $0.codeDevices[code] = device }
        }

        var target = URLComponents(string: redirect)
        var items = target?.queryItems ?? []
        if flow == .legacySSO {
            items.append(URLQueryItem(name: "loginToken", value: code))
        } else {
            items.append(URLQueryItem(name: "code", value: code))
            if let state = query["state"] { items.append(URLQueryItem(name: "state", value: state)) }
        }
        target?.queryItems = items
        return ProxiedResponse(status: 302, headers: ["Location": target?.string ?? redirect])
    }

    private func token(_ form: [String: String]) -> ProxiedResponse {
        let user: String?
        let device: String?
        switch form["grant_type"] {
        case "authorization_code":
            let code = form["code"] ?? ""
            (user, device) = state.withLock {
                ($0.codes.removeValue(forKey: code), $0.codeDevices.removeValue(forKey: code))
            }
        case "refresh_token":
            let refresh = form["refresh_token"] ?? ""
            user = state.withLock { $0.codes.removeValue(forKey: refresh) }
            device = nil
        default:
            return .oauthError("unsupported_grant_type")
        }
        guard let user else { return .oauthError("invalid_grant") }

        let token = issueToken(for: user, device: device ?? Self.mint(prefix: "MOCK", length: 6))
        let refresh = Self.mint(prefix: "refresh_", length: 16)
        state.withLock { $0.codes[refresh] = user }
        return .json([
            "access_token": token,
            "refresh_token": refresh,
            "token_type": "Bearer",
            "expires_in": 3600,
            "scope": form["scope"] ?? "",
        ])
    }

    // MARK: - The page in the browser

    private enum Page: String {
        case signIn, register, legacySSO
    }

    private func page(for flow: Page,
                      query: [String: String],
                      problem: String? = nil) -> ProxiedResponse {
        let (title, button) = switch flow {
        case .register: ("Новый аккаунт на \(configuration.serverName)", "Создать")
        case .signIn, .legacySSO: ("Вход на \(configuration.serverName)", "Войти")
        }

        // Everything the approve step needs travels through the form, so this server keeps no
        // per-browser state and a page can be reloaded without breaking anything.
        var carried = query
        carried["flow"] = flow.rawValue
        if flow == .legacySSO, let redirect = query["redirectUrl"] {
            carried["redirect_uri"] = redirect
            carried.removeValue(forKey: "redirectUrl")
        }
        carried.removeValue(forKey: "username")
        carried.removeValue(forKey: "password")
        let hidden = carried
            .sorted { $0.key < $1.key }
            .map { #"<input type="hidden" name="\#(Self.escape($0.key))" value="\#(Self.escape($0.value))">"# }
            .joined(separator: "\n")

        let suggestion = flow == .register ? "" : (configuration.accounts.keys.sorted().first ?? "")
        let note = problem.map { #"<p class="problem">\#(Self.escape($0))</p>"# } ?? ""

        let html = """
        <!doctype html>
        <html lang="ru"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(Self.escape(title))</title>
        <style>
        :root { color-scheme: light dark; font: -apple-system-body; }
        body { margin: 0; padding: 32px 16px; font-family: -apple-system, system-ui, sans-serif; }
        main { max-width: 360px; margin: 0 auto; }
        h1 { font-size: 22px; } .tag { font-size: 13px; opacity: .6; }
        input:not([type=hidden]) { display: block; box-sizing: border-box; width: 100%; font-size: 17px;
          padding: 12px; margin: 8px 0; border-radius: 12px; border: 1px solid #8884; }
        button { width: 100%; font-size: 17px; padding: 14px; border-radius: 14px; border: 0;
          background: #f60; color: #fff; margin-top: 8px; }
        .problem { color: #d33; }
        </style></head><body><main>
        <p class="tag">Тестовый сервер Iskra — всё это понарошку</p>
        <h1>\(Self.escape(title))</h1>
        \(note)
        <form method="get" action="/_mock/oauth/approve">
        \(hidden)
        <input name="username" placeholder="Имя" autocapitalize="none" autocorrect="off" value="\(Self.escape(suggestion))">
        <input name="password" type="password" placeholder="Пароль">
        <button type="submit">\(button)</button>
        </form>
        </main></body></html>
        """
        return ProxiedResponse(status: 200,
                               headers: ["Content-Type": "text/html; charset=utf-8"],
                               body: Data(html.utf8))
    }

    // MARK: - Helpers

    private func issueToken(for user: String, device: String) -> String {
        let token = Self.mint(prefix: "mock_", length: 24)
        state.withLock {
            $0.tokens[token] = user
            $0.devices[token] = device
        }
        return token
    }

    private func userID(for name: String) -> String { "@\(name):\(configuration.serverName)" }

    /// "alice", "@alice", and "@alice:iskra.test" are all Alice.
    private func localPart(of typed: String) -> String {
        var name = typed.trimmingCharacters(in: .whitespaces).lowercased()
        if name.hasPrefix("@") { name.removeFirst() }
        if let colon = name.firstIndex(of: ":") { name = String(name[..<colon]) }
        return name
    }

    /// OIDC names the device in the scope: `urn:matrix:org.matrix.msc2967.client:device:ABCDEF`,
    /// or the stable `urn:matrix:client:device:ABCDEF`.
    static func device(inScope scope: String) -> String? {
        scope.split(separator: " ")
            .first { $0.contains(":device:") }
            .flatMap { $0.split(separator: ":").last.map(String.init) }
    }

    private static func bearer(_ request: ProxiedRequest) -> String? {
        guard let value = request.headers.first(where: { $0.key.lowercased() == "authorization" })?.value,
              value.hasPrefix("Bearer ") else { return nil }
        return String(value.dropFirst("Bearer ".count))
    }

    static func split(_ target: String) -> (path: String, query: [String: String]) {
        guard let components = URLComponents(string: target) else { return (target, [:]) }
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] {
            query[item.name] = item.value ?? ""
        }
        return (components.path, query)
    }

    private static func form(_ body: Data) -> [String: String] {
        let text = String(decoding: body, as: UTF8.self).replacingOccurrences(of: "+", with: " ")
        return split("/?" + text).query
    }

    private static func mint(prefix: String, length: Int) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        return prefix + String((0..<length).map { _ in alphabet.randomElement()! })
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

// MARK: - Responses

private extension ProxiedResponse {
    static func json(_ object: [String: Any], status: Int = 200) -> ProxiedResponse {
        let body = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        return ProxiedResponse(status: status, headers: ["Content-Type": "application/json"], body: body)
    }

    static func raw(_ body: Data) -> ProxiedResponse {
        ProxiedResponse(status: 200, headers: ["Content-Type": "application/json"], body: body)
    }

    static func error(_ code: String, _ message: String, status: Int) -> ProxiedResponse {
        .json(["errcode": code, "error": message], status: status)
    }

    static func oauthError(_ code: String) -> ProxiedResponse {
        .json(["error": code], status: 400)
    }

    static let unrecognized = error("M_UNRECOGNIZED", "Not implemented by the mock server", status: 404)
    static let notFound = error("M_NOT_FOUND", "Nothing here", status: 404)
    static let forbidden = error("M_FORBIDDEN", "Invalid username or password", status: 403)
    static let unknownToken = error("M_UNKNOWN_TOKEN", "Unknown access token", status: 401)
    static let badJSON = error("M_BAD_JSON", "Could not read that", status: 400)
}
