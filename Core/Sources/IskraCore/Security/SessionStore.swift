import Foundation
import Security
import MatrixRustSDK
import Synchronization

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
        self.init(sessionID: sessionID,
                  userID: session.userId,
                  deviceID: session.deviceId,
                  homeserverURL: session.homeserverUrl,
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

/// One signed-in account, as the switcher shows it: who it is, and which store is theirs.
///
/// Nothing in here is secret, but it lives in the Keychain beside the tokens anyway, and for a
/// reason worth keeping: the list of accounts on a device *is* the list of people who use it, and
/// the Keychain is the one place the app keeps things that must not be backed up or synced.
///
/// The name and the picture are a cache. They are written whenever the account is open and read
/// when it is not, because a dormant account has no client to ask — and a switcher that could only
/// show Matrix IDs for everybody but the person on screen would be a list of addresses.
public struct AccountRecord: Codable, Sendable, Equatable, Identifiable {
    public let sessionID: String
    public let userID: String
    public var displayName: String?
    public var avatarURL: String?

    public var id: String { sessionID }

    public init(sessionID: String, userID: String, displayName: String? = nil, avatarURL: String? = nil) {
        self.sessionID = sessionID
        self.userID = userID
        self.displayName = displayName
        self.avatarURL = avatarURL
    }
}

/// Reads and writes the signed-in accounts' secrets.
///
/// Every account has three items of its own, named after its session ID — its tokens, the key that
/// encrypts its Matrix store, and the key that encrypts its search index — and one item, `accounts`,
/// lists them in the order they were added and says which one is on screen.
///
/// **Per account, and not three items for the device.** It used to be the latter, and it was fine
/// while there was only ever one person: signing out removed everything with `removeAll()`. With two
/// accounts that same call is the first account's sign-out taking the second one's store key with
/// it — an encrypted database nobody can open, belonging to somebody who did nothing.
///
/// The index is written only by the app. The notification extension reads it, and writes nothing but
/// the one account's tokens after a refresh, so two processes never race to rewrite the list.
public struct SessionStore: Sendable {
    private enum Key {
        static let accounts = "accounts"

        static func session(_ id: String) -> String { "session.\(id)" }
        static func storePassphrase(_ id: String) -> String { "store-passphrase.\(id)" }
        static func searchIndexKey(_ id: String) -> String { "search-index-key.\(id)" }

        /// The layout from before there could be two accounts: one of each, for the device.
        /// Read only to move it — see `migrateLegacyIfNeeded`.
        enum Legacy {
            static let session = "session"
            static let storePassphrase = "store-passphrase"
            static let searchIndexKey = "search-index-key"
        }
    }

    /// The list and which one is on screen, as one item so the two can never disagree.
    private struct Index: Codable {
        var accounts: [AccountRecord] = []
        var activeSessionID: String?
    }

    /// Every change to the index is read, changed and written back, and two of those interleaving
    /// in one process would lose one of them. The SDK's refresh callback does not touch the index,
    /// so this is only ever held for a moment by the app's own calls.
    private static let indexLock = Mutex(())

    private let keychain: any SecretStoring

    /// Production always passes a `Keychain`. Tests pass an in-memory store, because
    /// an unsigned test binary cannot open the data-protection keychain at all.
    public init(secrets: any SecretStoring) {
        self.keychain = secrets
    }

    public init(environment: AppEnvironment = .default) {
        self.keychain = Keychain(accessGroup: environment.keychainAccessGroup)
    }

    // MARK: - Accounts

    /// Everyone signed in on this device, in the order they were added.
    public func accounts() throws -> [AccountRecord] {
        try migrateLegacyIfNeeded()
        return try index().accounts
    }

    /// The account on screen: the one last switched to, or — if that one has gone — the first.
    public func activeSessionID() throws -> String? {
        try migrateLegacyIfNeeded()
        let index = try index()
        if let active = index.activeSessionID, index.accounts.contains(where: { $0.sessionID == active }) {
            return active
        }
        return index.accounts.first?.sessionID
    }

    public func setActive(_ sessionID: String) throws {
        try updateIndex { index in
            guard index.accounts.contains(where: { $0.sessionID == sessionID }) else { return }
            index.activeSessionID = sessionID
        }
    }

    /// Adds a freshly signed-in account to the list, saves its tokens, and puts it on screen.
    ///
    /// The tokens go in first. A crash between the two leaves tokens nobody lists, which cost
    /// nothing, and never a listed account with nothing to sign in with.
    public func register(_ session: StoredSession) throws {
        try save(session)
        try updateIndex { index in
            if let existing = index.accounts.firstIndex(where: { $0.sessionID == session.sessionID }) {
                index.accounts[existing] = AccountRecord(sessionID: session.sessionID,
                                                         userID: session.userID,
                                                         displayName: index.accounts[existing].displayName,
                                                         avatarURL: index.accounts[existing].avatarURL)
            } else {
                index.accounts.append(AccountRecord(sessionID: session.sessionID, userID: session.userID))
            }
            index.activeSessionID = session.sessionID
        }
    }

    /// Remembers what the account looks like, for the moments it is not open to ask.
    ///
    /// Compared first, so that the profile settling on the same name for the hundredth time does
    /// not rewrite a Keychain item each time.
    public func updateProfile(sessionID: String, displayName: String?, avatarURL: String?) throws {
        let current = try index().accounts.first { $0.sessionID == sessionID }
        guard let current, current.displayName != displayName || current.avatarURL != avatarURL else { return }

        try updateIndex { index in
            guard let position = index.accounts.firstIndex(where: { $0.sessionID == sessionID }) else { return }
            index.accounts[position].displayName = displayName
            index.accounts[position].avatarURL = avatarURL
        }
    }

    // MARK: - Session

    /// The tokens of the account on screen, or nil when nobody is signed in.
    public func loadSession() throws -> StoredSession? {
        guard let id = try activeSessionID() else { return nil }
        return try loadSession(id: id)
    }

    public func loadSession(id: String) throws -> StoredSession? {
        try migrateLegacyIfNeeded()
        guard let data = try keychain.data(for: Key.session(id)) else { return nil }
        return try JSONDecoder().decode(StoredSession.self, from: data)
    }

    /// Writes one account's tokens, and nothing else.
    ///
    /// This is what a token refresh calls, synchronously and from a Rust thread, possibly in the
    /// notification extension — so it deliberately does not touch the index. Adding somebody to
    /// the list is `register`, and only a sign-in does that.
    public func save(_ session: StoredSession) throws {
        try keychain.set(try JSONEncoder().encode(session), for: Key.session(session.sessionID))
    }

    /// Forgets one account entirely: secrets first, so that a crash midway through can never leave
    /// an encrypted store on disk that we still hold the key to.
    ///
    /// Only this account's. Everybody else on the device keeps their tokens, their keys, their
    /// store and their place in the list. If it was the one on screen, the next one in the list is.
    public func remove(sessionID: String, environment: AppEnvironment) throws {
        try discardSecrets(forSessionID: sessionID)
        try updateIndex { index in
            index.accounts.removeAll { $0.sessionID == sessionID }
            if index.activeSessionID == sessionID {
                index.activeSessionID = index.accounts.first?.sessionID
            }
        }
        Self.removeDirectories(forSessionID: sessionID, environment: environment)
    }

    /// Every account on the device, gone.
    public func clear(environment: AppEnvironment) throws {
        let ids = (try? accounts().map(\.sessionID)) ?? []
        try keychain.removeAll()
        for id in ids {
            Self.removeDirectories(forSessionID: id, environment: environment)
        }
    }

    /// The three keys of a session that is not going to be used — an abandoned sign-in attempt, or
    /// an account being removed. Its directories are the caller's to delete.
    public func discardSecrets(forSessionID id: String) throws {
        try keychain.removeItem(for: Key.session(id))
        try keychain.removeItem(for: Key.storePassphrase(id))
        try keychain.removeItem(for: Key.searchIndexKey(id))
    }

    /// If the container cannot be resolved there is nothing on disk to delete, and the secrets —
    /// the part that matters — are already gone.
    private static func removeDirectories(forSessionID id: String, environment: AppEnvironment) {
        guard let urls = try? [environment.sessionDataURL(forSessionID: id),
                               environment.sessionCachesURL(forSessionID: id),
                               environment.searchIndexURL(forSessionID: id)] else { return }
        for url in urls {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Encryption keys

    /// The passphrase the SDK uses to encrypt this session's SQLite store.
    public func storePassphrase(forSessionID id: String) throws -> String {
        try migrateLegacyIfNeeded()
        return try existingOrNewRandomSecret(for: Key.storePassphrase(id))
    }

    /// The passphrase the SDK uses to encrypt this session's local search index.
    public func searchIndexPassword(forSessionID id: String) throws -> String {
        try migrateLegacyIfNeeded()
        return try existingOrNewRandomSecret(for: Key.searchIndexKey(id))
    }

    private func existingOrNewRandomSecret(for key: String) throws -> String {
        if let existing = try keychain.data(for: key), let secret = String(data: existing, encoding: .utf8) {
            return secret
        }
        let secret = try Self.randomSecret()
        try keychain.set(Data(secret.utf8), for: key)
        return secret
    }

    // MARK: - The index

    private func index() throws -> Index {
        guard let data = try keychain.data(for: Key.accounts) else { return Index() }
        return try JSONDecoder().decode(Index.self, from: data)
    }

    private func updateIndex(_ change: (inout Index) -> Void) throws {
        try Self.indexLock.withLock { _ in
            var index = try index()
            change(&index)
            try keychain.set(try JSONEncoder().encode(index), for: Key.accounts)
        }
    }

    // MARK: - Moving the old layout

    /// Moves a device signed in before accounts were per-account into the new layout, once.
    ///
    /// **The session ID is kept, and that is the whole of it.** It names the three directories the
    /// encrypted store lives in, and the passphrase is carried across under the same ID — so the
    /// person who updates the app opens it on the same conversations, with nothing to download
    /// and nothing to verify again. A migration that minted a new ID would be a sign-out in all
    /// but name.
    ///
    /// Copy first, delete last, and every step is safe to repeat: the app and the notification
    /// extension can both arrive here at once after an update, and whichever finishes second finds
    /// the new items already there and the old ones already gone.
    private func migrateLegacyIfNeeded() throws {
        guard let data = try keychain.data(for: Key.Legacy.session) else { return }
        let legacy = try JSONDecoder().decode(StoredSession.self, from: data)
        let id = legacy.sessionID

        for (old, new) in [(Key.Legacy.storePassphrase, Key.storePassphrase(id)),
                           (Key.Legacy.searchIndexKey, Key.searchIndexKey(id))] {
            if try keychain.data(for: new) == nil, let secret = try keychain.data(for: old) {
                try keychain.set(secret, for: new)
            }
        }
        if try keychain.data(for: Key.session(id)) == nil {
            try save(legacy)
        }
        try updateIndex { index in
            if !index.accounts.contains(where: { $0.sessionID == id }) {
                index.accounts.append(AccountRecord(sessionID: id, userID: legacy.userID))
            }
            if index.activeSessionID == nil {
                index.activeSessionID = id
            }
        }

        try keychain.removeItem(for: Key.Legacy.session)
        try keychain.removeItem(for: Key.Legacy.storePassphrase)
        try keychain.removeItem(for: Key.Legacy.searchIndexKey)

        // The nicknames belong to the same person, so they move with them.
        LocalNames.adoptLegacyTable(forAccount: id)
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
