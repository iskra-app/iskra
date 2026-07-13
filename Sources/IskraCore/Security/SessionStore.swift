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

    init(sessionID: String, session: Session) {
        self.sessionID = sessionID
        self.userID = session.userId
        self.deviceID = session.deviceId
        self.homeserverURL = session.homeserverUrl
        self.accessToken = session.accessToken
        self.refreshToken = session.refreshToken
        self.oauthData = session.oauthData
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
        let secret = Self.randomSecret()
        try keychain.set(Data(secret.utf8), for: key)
        return secret
    }

    /// 32 bytes from the system CSPRNG, base64'd so it survives being a `String`.
    static func randomSecret() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "The system CSPRNG failed; refusing to invent a key.")
        return Data(bytes).base64EncodedString()
    }
}
