import Testing
import Foundation
import MatrixRustSDK
@testable import IskraCore

/// Stands in for the Keychain, which an unsigned `swift test` binary cannot open at all
/// (`errSecMissingEntitlement`, -34018). Same reason as `HomeserverDiscoveryTests`.
private final class InMemorySecrets: SecretStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]

    func data(for key: String) throws -> Data? {
        lock.withLock { items[key] }
    }

    func set(_ data: Data, for key: String) throws {
        lock.withLock { items[key] = data }
    }

    func removeItem(for key: String) throws {
        lock.withLock { _ = items.removeValue(forKey: key) }
    }

    func removeAll() throws {
        lock.withLock { items.removeAll() }
    }
}

/// What happens to the session on disk when the SDK refreshes a token.
///
/// The answer used to be "nothing", and that is the whole reason this file exists. The tokens
/// were written once, at sign-in, and the SDK then went on refreshing them in memory — so the
/// Keychain held a refresh token that had already been spent, and the *next cold start*
/// presented it, was refused, and dropped the user at the sign-in screen with no explanation.
///
/// These pin the two halves of the fix: the refreshed pair really does land on disk, and the
/// session ID — which names the three directories the encrypted store lives in, and which the
/// SDK's own `Session` knows nothing about — survives the round trip.
@Suite
struct SessionPersistenceTests {
    private func session(accessToken: String,
                         refreshToken: String,
                         userID: String = "@boris:matrix.org") -> Session {
        Session(accessToken: accessToken,
                refreshToken: refreshToken,
                userId: userID,
                deviceId: "DEVICE",
                homeserverUrl: "https://matrix.org",
                oauthData: nil,
                slidingSyncVersion: .native)
    }

    @Test("a refreshed token replaces the one on disk")
    func refreshedTokenIsSaved() throws {
        let store = SessionStore(secrets: InMemorySecrets())
        let delegate = SessionDelegate(sessionStore: store, sessionID: "session-1")

        try store.register(StoredSession(sessionID: "session-1",
                                         session: session(accessToken: "first", refreshToken: "old")))

        // The SDK, on a Rust thread, in the middle of a refresh.
        delegate.saveSessionInKeychain(session: session(accessToken: "second", refreshToken: "new"))

        let stored = try #require(try store.loadSession(id: "session-1"))
        #expect(stored.accessToken == "second")
        #expect(stored.refreshToken == "new")
    }

    /// The one that would have been a silent data loss rather than a silent sign-out.
    ///
    /// `Session` carries tokens and no session ID: it is the SDK's type and it has never heard of
    /// our directories. Build a `StoredSession` from it without carrying the ID across, and the
    /// app comes back next launch pointing at a store that does not exist — while the real one,
    /// full of room keys, sits on the disk under an ID nobody remembers.
    @Test("the session ID survives a refresh, so the store on disk stays findable")
    func refreshKeepsTheSessionID() throws {
        let store = SessionStore(secrets: InMemorySecrets())
        let delegate = SessionDelegate(sessionStore: store, sessionID: "session-1")

        try store.register(StoredSession(sessionID: "session-1",
                                         session: session(accessToken: "first", refreshToken: "old")))

        delegate.saveSessionInKeychain(session: session(accessToken: "second", refreshToken: "new"))

        let stored = try #require(try store.loadSession())
        #expect(stored.sessionID == "session-1")
    }

    /// Two accounts, two clients, two delegates — and one account's refresh must land in its own
    /// record. With one delegate for the service, told which session it served just before each
    /// build, the second build retargeted it and the first account's tokens went into the second's.
    @Test("each account's refresh lands in its own record")
    func refreshesStayWithTheirAccount() throws {
        let store = SessionStore(secrets: InMemorySecrets())
        try store.register(StoredSession(sessionID: "one", session: session(accessToken: "a1", refreshToken: "r1")))
        try store.register(StoredSession(sessionID: "two",
                                         session: session(accessToken: "b1", refreshToken: "s1",
                                                          userID: "@anya:matrix.org")))

        let first = SessionDelegate(sessionStore: store, sessionID: "one")
        let second = SessionDelegate(sessionStore: store, sessionID: "two")

        first.saveSessionInKeychain(session: session(accessToken: "a2", refreshToken: "r2"))

        #expect(try store.loadSession(id: "one")?.accessToken == "a2")
        #expect(try store.loadSession(id: "two")?.accessToken == "b1")
        #expect(try second.retrieveSessionFromKeychain(userId: "@anya:matrix.org").accessToken == "b1")
    }

    @Test("the SDK gets back the session it asks for")
    func retrievesTheSession() throws {
        let store = SessionStore(secrets: InMemorySecrets())
        let delegate = SessionDelegate(sessionStore: store, sessionID: "session-1")

        try store.register(StoredSession(sessionID: "session-1",
                                         session: session(accessToken: "first", refreshToken: "old")))

        let restored = try delegate.retrieveSessionFromKeychain(userId: "@boris:matrix.org")
        #expect(restored.accessToken == "first")
        #expect(restored.refreshToken == "old")
        #expect(restored.userId == "@boris:matrix.org")
    }

    @Test("somebody else's tokens are not handed over")
    func refusesTheWrongUser() throws {
        let store = SessionStore(secrets: InMemorySecrets())
        let delegate = SessionDelegate(sessionStore: store, sessionID: "session-1")

        try store.register(StoredSession(sessionID: "session-1",
                                         session: session(accessToken: "first", refreshToken: "old")))

        #expect(throws: SessionDelegateError.self) {
            try delegate.retrieveSessionFromKeychain(userId: "@anya:matrix.org")
        }
    }

    @Test("with nobody signed in, there is nothing to hand over")
    func refusesWhenSignedOut() throws {
        let store = SessionStore(secrets: InMemorySecrets())
        let delegate = SessionDelegate(sessionStore: store, sessionID: "session-1")

        #expect(throws: SessionDelegateError.self) {
            try delegate.retrieveSessionFromKeychain(userId: "@boris:matrix.org")
        }
    }
}

/// The store itself, which had no tests at all — while `SecretStoring` exists for the sole purpose
/// of making it testable without a Keychain the test binary cannot open.
///
/// What is pinned here is not the plumbing but the two promises the rest of the app is built on:
/// the keys that encrypt the store and the search index are **stable** across calls (fetch one
/// twice and it is the same key, or the database will not open tomorrow) and **different** from
/// each other (one key for two stores is one key to lose).
@Suite
struct SessionStoreTests {
    @Test("the store passphrase is the same one every time it is asked for")
    func passphraseIsStable() throws {
        let store = SessionStore(secrets: InMemorySecrets())

        let first = try store.storePassphrase(forSessionID: "one")
        let second = try store.storePassphrase(forSessionID: "one")

        #expect(first == second)
        #expect(!first.isEmpty)
    }

    /// Two stores, two keys. Sharing one would mean that losing it loses both — and that the search
    /// index, which is a second plaintext copy of every message, is protected by exactly the same
    /// secret as the thing it is a copy of.
    @Test("the search index has a key of its own")
    func searchKeyDiffersFromThePassphrase() throws {
        let store = SessionStore(secrets: InMemorySecrets())

        #expect(try store.storePassphrase(forSessionID: "one") != store.searchIndexPassword(forSessionID: "one"))
    }

    @Test("a fresh secret is 32 bytes and never the same twice")
    func secretsAreRandom() throws {
        let first = try SessionStore.randomSecret()
        let second = try SessionStore.randomSecret()

        #expect(first != second)
        // Base64 of 32 bytes: 44 characters, the last of which is padding.
        #expect(Data(base64Encoded: first)?.count == 32)
    }

    @Test("forgetting everybody forgets the session")
    func clearForgetsEverything() throws {
        let store = SessionStore(secrets: InMemorySecrets())

        try store.register(StoredSession(sessionID: "session-1",
                                     session: Session(accessToken: "token",
                                                      refreshToken: nil,
                                                      userId: "@boris:matrix.org",
                                                      deviceId: "DEVICE",
                                                      homeserverUrl: "https://matrix.org",
                                                      oauthData: nil,
                                                      slidingSyncVersion: .native)))
        #expect(try store.loadSession() != nil)

        try store.clear(environment: AppEnvironment(storage: .standalone))

        #expect(try store.loadSession() == nil)
    }

    // MARK: - More than one account

    private func stored(_ id: String, user: String, token: String = "token") -> StoredSession {
        StoredSession(sessionID: id,
                      session: Session(accessToken: token,
                                       refreshToken: nil,
                                       userId: user,
                                       deviceId: "DEVICE",
                                       homeserverUrl: "https://matrix.org",
                                       oauthData: nil,
                                       slidingSyncVersion: .native))
    }

    @Test("two accounts are listed in the order they were added, the newest on screen")
    func twoAccountsAreListed() throws {
        let store = SessionStore(secrets: InMemorySecrets())
        try store.register(stored("one", user: "@boris:matrix.org"))
        try store.register(stored("two", user: "@anya:example.org"))

        #expect(try store.accounts().map(\.sessionID) == ["one", "two"])
        #expect(try store.activeSessionID() == "two")

        try store.setActive("one")
        #expect(try store.loadSession()?.userID == "@boris:matrix.org")
    }

    /// The bug this layout exists to prevent: signing out used to be `removeAll()`, which with two
    /// accounts is the first one's sign-out taking the second one's store key with it.
    @Test("signing out of one account leaves the other one whole")
    func removingOneKeepsTheOther() throws {
        let store = SessionStore(secrets: InMemorySecrets())
        try store.register(stored("one", user: "@boris:matrix.org"))
        try store.register(stored("two", user: "@anya:example.org"))
        let key = try store.storePassphrase(forSessionID: "two")
        let search = try store.searchIndexPassword(forSessionID: "two")

        try store.remove(sessionID: "one", environment: AppEnvironment(storage: .standalone))

        #expect(try store.accounts().map(\.sessionID) == ["two"])
        #expect(try store.loadSession(id: "one") == nil)
        #expect(try store.loadSession(id: "two") != nil)
        #expect(try store.storePassphrase(forSessionID: "two") == key)
        #expect(try store.searchIndexPassword(forSessionID: "two") == search)
    }

    @Test("when the account on screen leaves, the next one is on screen")
    func removingTheActiveOneMovesOn() throws {
        let store = SessionStore(secrets: InMemorySecrets())
        try store.register(stored("one", user: "@boris:matrix.org"))
        try store.register(stored("two", user: "@anya:example.org"))

        try store.remove(sessionID: "two", environment: AppEnvironment(storage: .standalone))

        #expect(try store.activeSessionID() == "one")
    }

    @Test("every account has keys of its own")
    func keysAreNotShared() throws {
        let store = SessionStore(secrets: InMemorySecrets())
        #expect(try store.storePassphrase(forSessionID: "one") != store.storePassphrase(forSessionID: "two"))
    }

    @Test("a token refresh does not put anybody in the list")
    func savingTokensDoesNotRegister() throws {
        let store = SessionStore(secrets: InMemorySecrets())
        try store.save(stored("one", user: "@boris:matrix.org"))
        #expect(try store.accounts().isEmpty)
    }

    @Test("the name and picture are remembered for when the account is not open")
    func profileIsRemembered() throws {
        let store = SessionStore(secrets: InMemorySecrets())
        try store.register(stored("one", user: "@boris:matrix.org"))
        try store.updateProfile(sessionID: "one", displayName: "Борис", avatarURL: "mxc://matrix.org/abc")

        let account = try #require(try store.accounts().first)
        #expect(account.displayName == "Борис")
        #expect(account.avatarURL == "mxc://matrix.org/abc")
    }

    /// Somebody updates the app while signed in. They must open it on the same account, the same
    /// store and the same keys — a new session ID would be a sign-out in all but name.
    @Test("a device signed in before accounts moves across with its store and keys")
    func legacyLayoutMigrates() throws {
        let secrets = InMemorySecrets()
        let legacy = stored("old-id", user: "@boris:matrix.org")
        try secrets.set(try JSONEncoder().encode(legacy), for: "session")
        try secrets.set(Data("the-passphrase".utf8), for: "store-passphrase")
        try secrets.set(Data("the-search-key".utf8), for: "search-index-key")

        let store = SessionStore(secrets: secrets)

        #expect(try store.accounts().map(\.sessionID) == ["old-id"])
        #expect(try store.activeSessionID() == "old-id")
        #expect(try store.loadSession()?.accessToken == "token")
        #expect(try store.storePassphrase(forSessionID: "old-id") == "the-passphrase")
        #expect(try store.searchIndexPassword(forSessionID: "old-id") == "the-search-key")

        // And the old items are gone, so it happens once.
        #expect(try secrets.data(for: "session") == nil)
        #expect(try secrets.data(for: "store-passphrase") == nil)
    }

    /// The app and the extension can both reach the migration after an update. Whichever arrives
    /// second must find nothing to do, and must not add the account twice.
    @Test("moving the old layout twice changes nothing")
    func migrationIsRepeatable() throws {
        let secrets = InMemorySecrets()
        let legacy = stored("old-id", user: "@boris:matrix.org")
        try secrets.set(try JSONEncoder().encode(legacy), for: "session")
        try secrets.set(Data("the-passphrase".utf8), for: "store-passphrase")

        let store = SessionStore(secrets: secrets)
        _ = try store.accounts()

        // As if a second process had got as far as copying before the first one deleted.
        try secrets.set(try JSONEncoder().encode(legacy), for: "session")
        try secrets.set(Data("a-different-one".utf8), for: "store-passphrase")

        #expect(try store.accounts().count == 1)
        #expect(try store.storePassphrase(forSessionID: "old-id") == "the-passphrase")
    }
}
