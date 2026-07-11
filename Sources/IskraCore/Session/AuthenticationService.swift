import Foundation
import MatrixRustSDK

/// How a given homeserver is willing to let this user sign in.
///
/// Matrix has three answers to this and the user should never have to care which
/// one they got. We probe, pick the best available, and the UI just shows either a
/// "Continue" button (both SSO flavours look identical to a human) or a
/// username/password form.
public struct SignInOptions: Sendable, Equatable {
    /// Modern OAuth 2.0 / OIDC, as used by Matrix Authentication Service.
    public let supportsOAuth: Bool
    /// The older redirect-to-a-web-page SSO.
    public let supportsLegacySSO: Bool
    public let supportsPassword: Bool
    /// The address we actually resolved, which may differ from what was typed
    /// (typing "example.com" can resolve to "https://matrix.example.com").
    public let resolvedHomeserverURL: String

    /// True when the user can sign in by tapping one button and using their browser.
    public var canUseSingleSignOn: Bool { supportsOAuth || supportsLegacySSO }
}

public enum AuthenticationError: Error {
    /// We could not find a Matrix server at that address.
    case homeserverNotFound
    /// We could not open the encrypted store or reach the Keychain.
    ///
    /// Kept separate from `homeserverNotFound` on purpose. Folding the two together
    /// would report a Keychain entitlement problem to the user as "check the address
    /// you typed", which is untrue and impossible to act on.
    case storageUnavailable(Error)
    /// The server does not offer any sign-in method we can drive.
    case noSupportedSignInMethod
    /// `startSignIn` was not called, or the flow was abandoned.
    case noSignInInProgress
    case invalidCallbackURL
    case sdk(Error)
}

/// Owns the sign-in flow and, once it succeeds, hands back a live `Client`.
///
/// Nothing here logs a token, a password, or a callback URL — callback URLs carry
/// the authorization code, so they are as sensitive as the token they buy.
public actor AuthenticationService {
    private let environment: AppEnvironment
    private let sessionStore: SessionStore

    /// The client we are mid-sign-in with. Discarded if the flow is abandoned.
    private var pendingClient: Client?
    private var pendingSessionID: String?
    private var pendingOAuth: OAuthAuthorizationData?
    private var pendingSSO: SsoHandler?

    public init(environment: AppEnvironment = .default,
                sessionStore: SessionStore? = nil) {
        self.environment = environment
        self.sessionStore = sessionStore ?? SessionStore(environment: environment)
    }

    // MARK: - Restoring

    /// Brings back the previously signed-in user, if there is one.
    public func restorePreviousSession() async throws -> Client? {
        guard let stored = try sessionStore.loadSession() else { return nil }

        let client = try await makeClientBuilder(sessionID: stored.sessionID)
            .homeserverUrl(url: stored.homeserverURL)
            .build()

        try await client.restoreSession(session: stored.rustSession)
        return client
    }

    // MARK: - Signing in

    /// Points us at a homeserver and reports how the user may sign in to it.
    ///
    /// `address` is whatever the user typed: "matrix.org", "example.com", or a full
    /// URL. The SDK does well-known discovery, so a bare domain is fine.
    public func startSignIn(homeserverAddress address: String) async throws -> SignInOptions {
        let sessionID = UUID().uuidString

        // Two failures live here and they are not the same failure. Setting up the
        // encrypted store can fail (no Keychain, no disk); finding the server can
        // fail (typo, no network, not a homeserver). Only the second one is the
        // user's to fix, so only the second one may be reported as such.
        let builder: ClientBuilder
        do {
            builder = try makeClientBuilder(sessionID: sessionID)
        } catch {
            throw AuthenticationError.storageUnavailable(error)
        }

        let client: Client
        do {
            client = try await builder
                .serverNameOrHomeserverUrl(serverNameOrUrl: address)
                .build()
        } catch {
            throw AuthenticationError.homeserverNotFound
        }

        let details = await client.homeserverLoginDetails()

        pendingClient = client
        pendingSessionID = sessionID

        let options = SignInOptions(supportsOAuth: details.supportsOauthLogin(),
                                    supportsLegacySSO: details.supportsSsoLogin(),
                                    supportsPassword: details.supportsPasswordLogin(),
                                    resolvedHomeserverURL: details.url())

        guard options.canUseSingleSignOn || options.supportsPassword else {
            throw AuthenticationError.noSupportedSignInMethod
        }
        return options
    }

    /// The URL to open in the browser for single sign-on.
    ///
    /// Prefers OAuth when the server has it and silently falls back to legacy SSO,
    /// because from the user's point of view these are the same act.
    public func singleSignOnURL() async throws -> URL {
        guard let client = pendingClient else { throw AuthenticationError.noSignInInProgress }

        let urlString: String
        if await client.homeserverLoginDetails().supportsOauthLogin() {
            let data = try await client.urlForOauth(oauthConfiguration: oauthConfiguration(),
                                                    prompt: nil,
                                                    loginHint: nil,
                                                    deviceId: nil,
                                                    additionalScopes: nil)
            pendingOAuth = data
            urlString = data.loginUrl()
        } else {
            let handler = try await client.startSsoLogin(redirectUrl: environment.oauthRedirectURI, idpId: nil)
            pendingSSO = handler
            urlString = handler.url()
        }

        guard let url = URL(string: urlString) else { throw AuthenticationError.invalidCallbackURL }
        return url
    }

    /// Finishes single sign-on once the browser redirects back to us.
    public func completeSingleSignOn(callbackURL: URL) async throws -> Client {
        guard let client = pendingClient, let sessionID = pendingSessionID else {
            throw AuthenticationError.noSignInInProgress
        }

        do {
            if pendingOAuth != nil {
                try await client.loginWithOauthCallback(callbackUrl: callbackURL.absoluteString)
            } else if let handler = pendingSSO {
                try await handler.finish(callbackUrl: callbackURL.absoluteString)
            } else {
                throw AuthenticationError.noSignInInProgress
            }
        } catch let error as AuthenticationError {
            throw error
        } catch {
            throw AuthenticationError.sdk(error)
        }

        return try persist(client: client, sessionID: sessionID)
    }

    /// The fallback for homeservers without any SSO.
    public func signIn(username: String, password: String) async throws -> Client {
        guard let client = pendingClient, let sessionID = pendingSessionID else {
            throw AuthenticationError.noSignInInProgress
        }

        do {
            try await client.login(username: username,
                                   password: password,
                                   initialDeviceName: Self.deviceName,
                                   deviceId: nil)
        } catch {
            throw AuthenticationError.sdk(error)
        }

        return try persist(client: client, sessionID: sessionID)
    }

    /// Abandons a half-finished sign-in and lets the SDK tear down its side.
    public func cancelSignIn() async {
        if let client = pendingClient, let data = pendingOAuth {
            await client.abortOauthAuth(authorizationData: data)
        }
        pendingClient = nil
        pendingSessionID = nil
        pendingOAuth = nil
        pendingSSO = nil
    }

    // MARK: - Signing out

    public func signOut(client: Client) async {
        // Ask the server to forget the device first; even if that fails we still
        // destroy everything locally, because a stale device on the server is a far
        // smaller problem than keys left on a device the user thinks is signed out.
        try? await client.logout()
        try? sessionStore.clear(environment: environment)
    }

    // MARK: - Private

    private func persist(client: Client, sessionID: String) throws -> Client {
        let stored = StoredSession(sessionID: sessionID, session: try client.session())
        try sessionStore.save(stored)

        pendingClient = nil
        pendingSessionID = nil
        pendingOAuth = nil
        pendingSSO = nil

        return client
    }

    /// The one place a `ClientBuilder` is configured, so the security-relevant
    /// settings — an encrypted store and an encrypted search index — cannot be
    /// forgotten on one of the paths.
    private func makeClientBuilder(sessionID: String) throws -> ClientBuilder {
        let dataURL = environment.sessionDataURL(forSessionID: sessionID)
        let cacheURL = environment.sessionCachesURL(forSessionID: sessionID)
        let searchURL = environment.searchIndexURL(forSessionID: sessionID)

        for url in [dataURL, cacheURL, searchURL] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }

        // The SQLite store holds decrypted messages and the Megolm keys, so it is
        // encrypted at rest with a passphrase that exists only in the Keychain.
        let store = SqliteStoreBuilder(dataPath: dataURL.path(percentEncoded: false),
                                       cachePath: cacheURL.path(percentEncoded: false))
            .passphrase(passphrase: try sessionStore.storePassphrase())

        return ClientBuilder()
            .sqliteStore(config: store)
            // The search index is a second copy of every message we can read, so it
            // gets the same treatment rather than being left in the clear.
            .withSearchIndexStore(path: searchURL.path(percentEncoded: false),
                                  password: try sessionStore.searchIndexPassword())
            .slidingSyncVersionBuilder(versionBuilder: .discoverNative)
    }

    private func oauthConfiguration() -> OAuthConfiguration {
        OAuthConfiguration(clientName: environment.clientName,
                           redirectUri: environment.oauthRedirectURI,
                           clientUri: "https://iskra.app",
                           logoUri: nil,
                           tosUri: nil,
                           policyUri: nil,
                           staticRegistrations: [:])
    }

    /// Shown to the user in their list of signed-in devices, so it is a plain name
    /// rather than a model identifier.
    private static var deviceName: String {
        #if os(macOS)
        "Iskra on Mac"
        #elseif os(iOS)
        "Iskra on iPhone or iPad"
        #else
        "Iskra"
        #endif
    }
}
