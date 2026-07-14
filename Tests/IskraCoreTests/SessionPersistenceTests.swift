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
        let delegate = SessionDelegate(sessionStore: store)

        delegate.willBuildClient(forSessionID: "session-1")
        try store.save(StoredSession(sessionID: "session-1",
                                     session: session(accessToken: "first", refreshToken: "old")))

        // The SDK, on a Rust thread, in the middle of a refresh.
        delegate.saveSessionInKeychain(session: session(accessToken: "second", refreshToken: "new"))

        let stored = try #require(try store.loadSession())
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
        let delegate = SessionDelegate(sessionStore: store)

        delegate.willBuildClient(forSessionID: "session-1")
        try store.save(StoredSession(sessionID: "session-1",
                                     session: session(accessToken: "first", refreshToken: "old")))

        delegate.saveSessionInKeychain(session: session(accessToken: "second", refreshToken: "new"))

        let stored = try #require(try store.loadSession())
        #expect(stored.sessionID == "session-1")
    }

    /// A refresh that arrives for a client nobody told us about — the notification extension
    /// building its own — still has to find the ID, and the only other place it can be is disk.
    @Test("a refresh with nothing announced falls back to the session already on disk")
    func refreshFallsBackToDisk() throws {
        let store = SessionStore(secrets: InMemorySecrets())
        let delegate = SessionDelegate(sessionStore: store)

        try store.save(StoredSession(sessionID: "session-1",
                                     session: session(accessToken: "first", refreshToken: "old")))

        // No `willBuildClient` at all.
        delegate.saveSessionInKeychain(session: session(accessToken: "second", refreshToken: "new"))

        let stored = try #require(try store.loadSession())
        #expect(stored.sessionID == "session-1")
        #expect(stored.accessToken == "second")
    }

    @Test("the SDK gets back the session it asks for")
    func retrievesTheSession() throws {
        let store = SessionStore(secrets: InMemorySecrets())
        let delegate = SessionDelegate(sessionStore: store)

        try store.save(StoredSession(sessionID: "session-1",
                                     session: session(accessToken: "first", refreshToken: "old")))

        let restored = try delegate.retrieveSessionFromKeychain(userId: "@boris:matrix.org")
        #expect(restored.accessToken == "first")
        #expect(restored.refreshToken == "old")
        #expect(restored.userId == "@boris:matrix.org")
    }

    @Test("somebody else's tokens are not handed over")
    func refusesTheWrongUser() throws {
        let store = SessionStore(secrets: InMemorySecrets())
        let delegate = SessionDelegate(sessionStore: store)

        try store.save(StoredSession(sessionID: "session-1",
                                     session: session(accessToken: "first", refreshToken: "old")))

        #expect(throws: SessionDelegateError.self) {
            try delegate.retrieveSessionFromKeychain(userId: "@anya:matrix.org")
        }
    }

    @Test("with nobody signed in, there is nothing to hand over")
    func refusesWhenSignedOut() throws {
        let store = SessionStore(secrets: InMemorySecrets())
        let delegate = SessionDelegate(sessionStore: store)

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

        let first = try store.storePassphrase()
        let second = try store.storePassphrase()

        #expect(first == second)
        #expect(!first.isEmpty)
    }

    /// Two stores, two keys. Sharing one would mean that losing it loses both — and that the search
    /// index, which is a second plaintext copy of every message, is protected by exactly the same
    /// secret as the thing it is a copy of.
    @Test("the search index has a key of its own")
    func searchKeyDiffersFromThePassphrase() throws {
        let store = SessionStore(secrets: InMemorySecrets())

        #expect(try store.storePassphrase() != store.searchIndexPassword())
    }

    @Test("a fresh secret is 32 bytes and never the same twice")
    func secretsAreRandom() throws {
        let first = try SessionStore.randomSecret()
        let second = try SessionStore.randomSecret()

        #expect(first != second)
        // Base64 of 32 bytes: 44 characters, the last of which is padding.
        #expect(Data(base64Encoded: first)?.count == 32)
    }

    @Test("signing out forgets the session")
    func clearForgetsEverything() throws {
        let store = SessionStore(secrets: InMemorySecrets())

        try store.save(StoredSession(sessionID: "session-1",
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
}
