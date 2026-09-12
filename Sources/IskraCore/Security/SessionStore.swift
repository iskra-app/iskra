import Foundation
import Security
import MatrixRustSDK

/// Everything Iskra persists about a signed-in user. All of it is secret, so all of
/// it lives in the Keychain and none of it is ever written to disk in the clear.
public struct StoredSession: Codable, Sendable, Equatable {
    /// Names this session's directories on disk. Random, so that signing in twice
    /// never reuses a store, and signing out can delete one without touching another.
    public let sessionID: String

    public let userID: String
    public let deviceID: String
    public let homeserverURL: String
    public let accessToken: String
    public let refreshToken: String?
    /// Opaque OAuth state the SDK hands back; needed to refresh tokens later.
    public let oauthData: String?

    /// - Note: `homeserverURL` is deliberately **not** taken from the session as-is. With the
    ///   bridge switch on, the SDK's idea of its homeserver is `http://127.0.0.1:<port>` — this
    ///   launch's listener, on a port the system handed out for this launch only. Writing that
    ///   down is writing down an address that stops existing when the app quits, and the next
    ///   launch dials it and reports no network. `TunnelSettings.persistableHomeserver` swaps it
    ///   back for the homeserver the listener stands in for.
    init(sessionID: String, session: Session) {
        self.init(sessionID: sessionID,
                  userID: session.userId,
                  deviceID: session.deviceId,
                  homeserverURL: TunnelSettings.persistableHomeserver(session.homeserverUrl),
                  accessToken: session.accessToken,
                  refreshToken: session.refreshToken,
                  oauthData: session.oauthData)
    }

    init(sessionID: String,
         userID: String,
         deviceID: String,
         homeserverURL: String,
         accessToken: String,
         refreshToken: String?,
         oauthData: String?) {
        self.sessionID = sessionID
        self.userID = userID
        self.deviceID = deviceID
        self.homeserverURL = homeserverURL
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.oauthData = oauthData
    }

    /// The same session, pointed somewhere else. Used to repair a record that was written before
    /// the rule above existed, and to tell the SDK where it is restoring from.
    func with(homeserverURL: String) -> StoredSession {
        StoredSession(sessionID: sessionID,
                      userID: userID,
                      deviceID: deviceID,
                      homeserverURL: homeserverURL,
                      accessToken: accessToken,
                      refreshToken: refreshToken,
                      oauthData: oauthData)
    }

    /// The server name out of the user ID: `@ann:matrix.org` -> `matrix.org`.
    ///
    /// The last resort when the stored address is unusable. A Matrix user ID always carries the
    /// server it belongs to, which is why a poisoned record is recoverable at all.
    var serverName: String? {
        guard let colon = userID.firstIndex(of: ":") else { return nil }
        let name = String(userID[userID.index(after: colon)...])
        return name.isEmpty ? nil : name
    }

    /// Back into the shape the Rust SDK wants.
    var rustSession: Session {
        Session(accessToken: accessToken,
                refreshToken: refreshToken,
                userId: userID,
                deviceId: deviceID,
                homeserverUrl: homeserverURL,
                oauthData: oauthData,
                slidingSyncVersion: .native)
    }
}

/// Reads and writes the signed-in user's secrets.
///
/// Besides the session itself this owns two keys the user never sees: one that
/// encrypts the Matrix store (messages, room state, crypto keys) and one that
/// encrypts the local search index. Both are generated once, at random, and kept
/// only in the Keychain — losing them is fine, it just means the caches rebuild.
public struct SessionStore: Sendable {
    private enum Key {
        static let session = "session"
        static let storePassphrase = "store-passphrase"
        static let searchIndexKey = "search-index-key"
    }

    private let keychain: any SecretStoring

    /// Production always passes a `Keychain`. Tests pass an in-memory store, because
    /// an unsigned test binary cannot open the data-protection keychain at all.
    public init(secrets: any SecretStoring) {
        self.keychain = secrets
    }

    public init(environment: AppEnvironment = .default) {
        self.keychain = Keychain(accessGroup: environment.keychainAccessGroup)
    }

    // MARK: - Session

    public func loadSession() throws -> StoredSession? {
        guard let data = try keychain.data(for: Key.session) else { return nil }
        return try JSONDecoder().decode(StoredSession.self, from: data)
    }

    public func save(_ session: StoredSession) throws {
        try keychain.set(try JSONEncoder().encode(session), for: Key.session)
    }

    /// Forgets the user entirely: secrets first, so that a crash midway through
    /// can never leave an encrypted store on disk that we still hold the key to.
    public func clear(environment: AppEnvironment) throws {
        let session = try? loadSession()
        try keychain.removeAll()

        // If the container cannot be resolved there is nothing on disk to delete, and
        // the secrets — the part that matters — are already gone.
        if let sessionID = session?.sessionID,
           let urls = try? [environment.sessionDataURL(forSessionID: sessionID),
                            environment.sessionCachesURL(forSessionID: sessionID),
                            environment.searchIndexURL(forSessionID: sessionID)] {
            for url in urls {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    // MARK: - Encryption keys

    /// The passphrase the SDK uses to encrypt its SQLite store.
    public func storePassphrase() throws -> String {
        try existingOrNewRandomSecret(for: Key.storePassphrase)
    }

    /// The passphrase the SDK uses to encrypt the local search index.
    public func searchIndexPassword() throws -> String {
        try existingOrNewRandomSecret(for: Key.searchIndexKey)
    }

    private func existingOrNewRandomSecret(for key: String) throws -> String {
        if let existing = try keychain.data(for: key), let secret = String(data: existing, encoding: .utf8) {
            return secret
        }
        let secret = try Self.randomSecret()
        try keychain.set(Data(secret.utf8), for: key)
        return secret
    }

    /// 32 bytes from the system CSPRNG, base64'd so it survives being a `String`.
    ///
    /// It **throws** where it used to trap, and the refusal is unchanged: a key this app cannot
    /// generate properly is a key it must not invent. What changes is who dies for it.
    ///
    /// `precondition` kills the process. That is defensible in an app — the screen is there, the
    /// user sees a crash, somebody files a report — and it is indefensible in the notification
    /// extension, which calls this by way of `storePassphrase()` every time a push arrives. A trap
    /// there is a process that vanishes without a word: no notification, no log, no crash the user
    /// would ever connect to anything. Just a message that never appeared.
    ///
    /// Everything around this already throws (`storePassphrase()`, `searchIndexPassword()`), so the
    /// error travels the road that was already built for it.
    static func randomSecret() throws -> String {
        var bytes = [UInt8](repeating: 0, count: keyLength)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)

        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }

        return Data(bytes).base64EncodedString()
    }

    /// 256 bits. Named because it is a security parameter, and a security parameter written as a
    /// bare `32` in the middle of a line is one nobody will ever find again.
    private static let keyLength = 32
}
