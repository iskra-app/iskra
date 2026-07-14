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
    /// We found somewhere to ask, and it never answered.
    ///
    /// Separate from `homeserverNotFound` because the advice differs: a typo is not the
    /// problem, the network or the server is.
    case homeserverUnreachable
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

    /// What keeps the Keychain current after a token refresh. Built once, here, and handed to
    /// every `ClientBuilder` this service makes — see `SessionDelegate` for what goes wrong
    /// without it, which is an app that signs the user out overnight and cannot say why.
    private let sessionDelegate: SessionDelegate

    public init(environment: AppEnvironment = .default,
                sessionStore: SessionStore? = nil) {
        let store = sessionStore ?? SessionStore(environment: environment)

        self.environment = environment
        self.sessionStore = store
        self.sessionDelegate = SessionDelegate(sessionStore: store)
    }

    // MARK: - Restoring

    /// Brings back the previously signed-in user, if there is one.
    ///
    /// Bounded, like everything else the user waits on — and it was the one call that was not.
    /// This is what runs while the launch screen shows a spinner, and `restoreSession` reaches the
    /// network: a homeserver that accepts the connection and then says nothing left the app on that
    /// spinner **forever**, with no way out but killing it. The rule in `CLAUDE.md` — "every SDK
    /// call the user waits on is bounded" — had a hole in it exactly where the user waits longest.
    ///
    /// The same deadline covers the notification extension, which restores a session too and has
    /// thirty seconds to live before iOS takes the process away. See `PushDecoder`, whose budget
    /// used to start counting only after this had already returned.
    public func restorePreviousSession() async throws -> Client? {
        guard let stored = try sessionStore.loadSession() else { return nil }

        let builder: ClientBuilder
        do {
            builder = try makeClientBuilder(sessionID: stored.sessionID)
        } catch {
            throw AuthenticationError.storageUnavailable(error)
        }

        return try await withTimeout(Self.restoreTimeout) {
            let client = try await builder
                .homeserverUrl(url: stored.homeserverURL)
                .build()

            try await client.restoreSession(session: stored.rustSession)
            return client
        }
    }

    /// Long enough for a slow network and a large store, short enough that a server which is never
    /// going to answer does not hold the app on its launch screen indefinitely.
    private static let restoreTimeout: Duration = .seconds(20)

    // MARK: - Signing in

    /// Points us at a homeserver and reports how the user may sign in to it.
    ///
    /// `address` is whatever the user typed: "matrix.org", "example.com", or a full
    /// URL. The SDK does well-known discovery, so a bare domain is fine.
    public func startSignIn(homeserverAddress address: String) async throws -> SignInOptions {
        // Whatever the last attempt made for itself, it is not going to use. Typing a homeserver,
        // getting it wrong, and typing another is the ordinary way this screen is used, and each
        // pass through here mints a session ID and three directories to go with it.
        //
        // The *whole* attempt goes, not just its directories. Deleting the store while leaving
        // `pendingClient` and `pendingSessionID` pointing at it is worse than leaving both: the
        // client goes on holding files in a directory that is not there any more, and if the new
        // lookup then fails, the screen keeps the *old* options — so pressing "sign in" completes
        // the previous attempt and `persist()` writes a session to the Keychain whose encrypted
        // store was deleted a moment ago. An account that is signed in and has nowhere to keep
        // anything.
        if let abandoned = pendingSessionID {
            discardStore(forSessionID: abandoned)
        }
        pendingClient = nil
        pendingSessionID = nil
        pendingOAuth = nil
        pendingSSO = nil

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

        // Bounded, because everything past this point is the network. An unreachable
        // server — a homeserver on a LAN the phone is not on, a captive portal, a host
        // that accepts the connection and then says nothing — otherwise leaves the
        // "Continue" button spinning with no way out and nothing on screen to explain
        // it. A wrong answer the user can act on beats a spinner that never stops.
        let client: Client
        do {
            client = try await withTimeout(Self.lookupTimeout) {
                try await builder
                    .serverNameOrHomeserverUrl(serverNameOrUrl: address)
                    .build()
            }
        } catch is TimeoutError {
            throw AuthenticationError.homeserverUnreachable
        } catch {
            throw AuthenticationError.homeserverNotFound
        }

        let details: HomeserverLoginDetails
        do {
            details = try await withTimeout(Self.lookupTimeout) {
                await client.homeserverLoginDetails()
            }
        } catch {
            throw AuthenticationError.homeserverUnreachable
        }

        pendingClient = client
        pendingSessionID = sessionID

        // And the *previous* attempt's half-finished flow goes with it. It used to survive, and
        // `completeSingleSignOn` asks `if pendingOAuth != nil` first — so a user who opened the
        // browser against an OAuth server, backed out of it, and then typed a different address
        // that only speaks legacy SSO would come back to `loginWithOauthCallback` being called on
        // a client that never began an OAuth flow. The legacy branch was never reached, and the
        // sign-in failed with an SDK error that named none of this.
        pendingOAuth = nil
        pendingSSO = nil

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
        if let sessionID = pendingSessionID {
            discardStore(forSessionID: sessionID)
        }

        pendingClient = nil
        pendingSessionID = nil
        pendingOAuth = nil
        pendingSSO = nil
    }

    /// Deletes the directories a sign-in attempt made for itself and never used.
    ///
    /// `makeClientBuilder` creates three of them — data, caches, search index — for a fresh random
    /// session ID, and it does it *eagerly*, before the homeserver has even been looked up. So
    /// every attempt makes a set, and only the attempt that succeeds ever has a use for one.
    /// Nothing deleted the rest: mistype your homeserver three times before getting it right and
    /// you left three orphan directories inside the App Group container, one of which may hold a
    /// real SQLite store if the builder got as far as `build()`. They survived sign-out, too —
    /// `SessionStore.clear` only knows about the session that was actually saved — so they
    /// accumulated across the life of the install.
    /// Where the signed-in session's three stores are, by kind — what the storage screen adds up.
    ///
    /// Asked of the session that was actually *saved*, not of the one being signed in with: the
    /// same reasoning as `discardStore` below, from the other side. A failed sign-in attempt may
    /// have left a directory behind, and it is not this account's.
    /// `nonisolated` because it is a question about the *filesystem*, not about this actor's
    /// state: it reads the Keychain and joins paths, touching nothing that sign-in mutates. The
    /// screen that asks for it is built synchronously on a navigation push, and making it `await`
    /// would mean an actor hop for two directory names.
    nonisolated func storageURLs() -> [StorageKind: URL] {
        guard let id = (try? sessionStore.loadSession())?.sessionID else { return [:] }

        let urls: [StorageKind: URL?] = [
            .session: try? environment.sessionDataURL(forSessionID: id),
            .cache: try? environment.sessionCachesURL(forSessionID: id),
            .search: try? environment.searchIndexURL(forSessionID: id),
        ]
        return urls.compactMapValues { $0 }
    }

    /// Every encrypted store on the disk that no longer belongs to anybody.
    ///
    /// They accumulate, and they accumulate *silently*. A sign-in that fails halfway has already
    /// minted a session ID and three directories to go with it. A restore that throws — a timeout,
    /// a server that will not answer — leaves the app on the sign-in screen, and if the user then
    /// signs in again they get a new session ID and three new directories, while the old three stay
    /// where they are. Nobody deletes them, ever, and `storePassphrase()` is stable, so what is left
    /// behind is not inert: it is a *readable* copy of the conversations, sitting in the container
    /// with nothing pointing at it.
    ///
    /// The rule is the narrowest one that is still true: anything that is not the session in the
    /// Keychain is not a session at all. And it is only safe to say that at one moment — launch,
    /// before anybody has started signing in — because a sign-in *in progress* has directories on
    /// disk and no Keychain entry yet, and sweeping then would delete the attempt out from under
    /// itself. So this is called from `restore()` and nowhere else.
    ///
    /// Failures are ignored on purpose. This is housekeeping; a file that will not delete is not a
    /// reason to refuse to start.
    public func sweepOrphanedStores() {
        let current = (try? sessionStore.loadSession())?.sessionID

        guard let container = try? environment.containerURL() else { return }

        for kind in ["Sessions", "Caches", "Search"] {
            let parent = container.appending(component: kind)

            let contents = (try? FileManager.default.contentsOfDirectory(at: parent,
                                                                         includingPropertiesForKeys: nil)) ?? []

            for url in contents where url.lastPathComponent != current {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private func discardStore(forSessionID id: String) {
        let urls = [try? environment.sessionDataURL(forSessionID: id),
                    try? environment.sessionCachesURL(forSessionID: id),
                    try? environment.searchIndexURL(forSessionID: id)]

        for url in urls.compactMap({ $0 }) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Signing out

    public func signOut(client: Client) async {
        // Ask the server to forget the device first; even if that fails we still
        // destroy everything locally, because a stale device on the server is a far
        // smaller problem than keys left on a device the user thinks is signed out.
        //
        // Bounded, like every other SDK call the user waits on — and this one was not, which is
        // the whole of the bug it fixes. `logout()` reaches the network. A homeserver that accepts
        // the connection and then says nothing left the app with a spinner and no way out of it:
        // the sign-out never returned, so the tree above never got as far as `phase = .signedOut`,
        // and the screen it was signing out *of* stayed exactly where it was, alive, and dead to
        // the touch. There is nothing to retry and nothing to explain — the local half is what
        // signing out actually means, and it happens regardless.
        _ = try? await withTimeout(Self.logoutTimeout) {
            try await client.logout()
        }

        try? sessionStore.clear(environment: environment)
    }

    /// Long enough for a server that is merely slow, short enough that a server which is never
    /// going to answer does not get to keep the user signed in while it thinks about it.
    private static let logoutTimeout: Duration = .seconds(10)

    /// Forgets the session without asking the server to.
    ///
    /// For the sign-out nobody here performed: the server has stopped accepting this session —
    /// somebody ended it from another device, or the account was deactivated — and there is
    /// nothing left to log out *of*. Asking anyway would send a dead token to a server that has
    /// already said what it thinks of it, and then wait ten seconds to be told so again.
    ///
    /// Everything local still goes, and that is the part that matters: the keys, the tokens, and
    /// the encrypted store. A session the server has revoked must not leave the room keys sitting
    /// on the disk of a device that can no longer reach the account they belong to.
    public func forgetSession() {
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
        let dataURL = try environment.sessionDataURL(forSessionID: sessionID)
        let cacheURL = try environment.sessionCachesURL(forSessionID: sessionID)
        let searchURL = try environment.searchIndexURL(forSessionID: sessionID)

        for url in [dataURL, cacheURL, searchURL] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }

        // The SQLite store holds decrypted messages and the Megolm keys, so it is
        // encrypted at rest with a passphrase that exists only in the Keychain.
        let store = SqliteStoreBuilder(dataPath: dataURL.path(percentEncoded: false),
                                       cachePath: cacheURL.path(percentEncoded: false))
            .passphrase(passphrase: try sessionStore.storePassphrase())

        // Which session the tokens the SDK is about to refresh belong to. Said *before* the
        // client exists, because the first refresh can happen as early as `restoreSession`.
        sessionDelegate.willBuildClient(forSessionID: sessionID)

        return ClientBuilder()
            .sqliteStore(config: store)
            // The one thing that keeps the Keychain telling the truth about this session for
            // longer than an hour. The SDK refreshes tokens by itself and holds the new pair in
            // memory; without a delegate to hand them to, the pair on disk is the one from
            // sign-in, and a refresh token is single-use — so the *next cold start* presents a
            // dead token and the user is silently signed out. See `SessionDelegate`.
            .setSessionDelegate(sessionDelegate: sessionDelegate)
            // Back the room keys up from the start, and sign this device into the account's own
            // web of trust from the start. Both default to *off* in the SDK, and both were off.
            //
            // What that meant is worth saying in full, because nothing on any screen would have
            // said it: a person installs Iskra, talks to people for a year, and loses their phone.
            // The messages are on the server. The keys that open them were only ever on the phone.
            // There is no backup, because a backup is something you get by opening the encryption
            // screen and pressing a button nobody told you about — and the history is gone, all of
            // it, permanently.
            //
            // The recovery *key* stays manual, and should: it is the one secret only the user can
            // keep, and minting it behind their back would be a key nobody has written down. This
            // is the other half — the part that has to already be true by the time they think to
            // ask for one.
            .autoEnableBackups(autoEnableBackups: true)
            .autoEnableCrossSigning(autoEnableCrossSigning: true)
            // Two processes, one store. The notification extension opens the same SQLite file the
            // app has open — that is the whole design of it — and `notificationClient` was already
            // asking for `.multipleProcesses`, which locks the *crypto* store. It does not lock the
            // tokens.
            //
            // And the tokens are the thing both processes race for. A push arrives while the app is
            // running; the access token has expired; both go to refresh it; a refresh token is
            // single-use, so the second one to arrive presents a token the server has already
            // spent and is told the session is gone. What the user sees is an app that signed
            // itself out in the night. See also `SessionDelegate`, which is what makes the winner's
            // new token reach the disk at all.
            .crossProcessLockConfig(crossProcessLockConfig:
                .multiProcess(holderName: AppEnvironment.processName))
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

    /// Long enough for well-known discovery over a slow mobile connection, short enough
    /// that a person still believes the app is answering them.
    private static let lookupTimeout: Duration = .seconds(30)

    /// Shown to the user in their list of signed-in devices, so it is a plain name
    /// rather than a model identifier.
    private static var deviceName: String {
        #if os(macOS)
        String(core: CoreStrings.Device.mac)
        #elseif os(iOS)
        String(core: CoreStrings.Device.iOS)
        #else
        String(core: CoreStrings.Device.generic)
        #endif
    }
}
