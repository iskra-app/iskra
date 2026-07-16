import Foundation
import Synchronization
import MatrixRustSDK

/// Keeps the Keychain in step with the tokens the SDK is actually using.
///
/// This exists because of a bug that only shows itself a day later, in a way nobody would
/// connect to its cause.
///
/// The app used to write the session to the Keychain exactly once — in `persist()`, the moment
/// sign-in succeeded — and never again. Meanwhile the SDK refreshes tokens on its own (nothing
/// calls `disableAutomaticTokenRefresh`, and nothing should), and it keeps the new pair **in
/// memory**. So the tokens the client is using and the tokens on disk drift apart the first time
/// a refresh happens, and the Keychain quietly becomes a record of what used to be true.
///
/// That is survivable right up until the app is killed. Then `restorePreviousSession` hands the
/// server the *old* pair — and a refresh token is single-use under MAS: using it is what rotates
/// it, and the previous one is dead the moment its replacement is issued. The server says
/// `M_UNKNOWN_TOKEN`, restore throws, `IskraRootView` catches it and shows the sign-in screen.
/// The user was signed out overnight, by nobody, for no reason they can see — and the encrypted
/// store full of their room keys is still on the disk, orphaned, because the sign-out that would
/// have deleted it never happened.
///
/// The SDK has a door for exactly this and it was not being used: hand it something that can read
/// and write the session, and it will keep that store current itself, on every refresh, from
/// whatever thread the refresh happened on.
///
/// Two things about the shape of it are load-bearing:
///
/// - **It is not an actor and not `@MainActor`.** The SDK calls these methods *synchronously*,
///   from a Rust thread, in the middle of a token refresh. There is nowhere to `await` from. The
///   mutable state is one string behind a `Mutex`, and `SessionStore` is a `Sendable` value over
///   the Keychain, which is itself thread-safe.
///
/// - **The session ID survives the round trip.** The SDK's `Session` knows about tokens and knows
///   nothing about us: it does not carry the random ID that names this session's three directories
///   on disk. Saving a `StoredSession` built from it alone would mint a new ID, and the app would
///   come back to an encrypted store it could no longer find — the same data loss as the bug this
///   fixes, arrived at from the other side. So the ID is remembered here, told to us by
///   `AuthenticationService` before it builds a client, and written back with every refresh.
final class SessionDelegate: ClientSessionDelegate {
    private let sessionStore: SessionStore

    /// Which session's directories these tokens belong to. Set before a client is built — on both
    /// paths, signing in and restoring — and read again on every refresh for the life of the app.
    private let sessionID = Mutex<String?>(nil)

    init(sessionStore: SessionStore) {
        self.sessionStore = sessionStore
    }

    /// Told to us by `AuthenticationService`, which is the only thing that knows the ID: on a
    /// fresh sign-in it has just minted one, and on a restore it has just read one out of the
    /// Keychain.
    func willBuildClient(forSessionID id: String) {
        sessionID.withLock { $0 = id }
    }

    // MARK: - ClientSessionDelegate

    func retrieveSessionFromKeychain(userId: String) throws -> Session {
        guard let stored = try sessionStore.loadSession() else {
            throw SessionDelegateError.nobodySignedIn
        }

        // The SDK names the user it wants. It is always the one we hold — there is only ever one
        // session on this device — but agreeing to hand back somebody else's tokens because we
        // were not asked to check is not a thing to leave lying around in a file about tokens.
        guard stored.userID == userId else {
            throw SessionDelegateError.wrongUser
        }

        return stored.rustSession
    }

    func saveSessionInKeychain(session: Session) {
        // The ID we were told, or — for a client somebody built without telling us — the one
        // already on disk. If there is neither, this is a refresh for a session we have no record
        // of, and inventing an ID for it would create a second set of directories for a store
        // that already exists somewhere else.
        let existing = (try? sessionStore.loadSession())
        guard let id = sessionID.withLock({ $0 }) ?? existing?.sessionID else {
            Log.session.error("a token was refreshed for a session with no ID; not saving it")
            return
        }

        do {
            try sessionStore.save(StoredSession(sessionID: id, session: session))
        } catch {
            // Nothing to do about it here, and nothing the user could do either — but a refresh
            // that failed to land is precisely the thing that will look, tomorrow, like the app
            // signing them out for no reason. So it is said out loud, once, where the next hour
            // of debugging will find it.
            Log.session.error("""
                the refreshed token would not go into the Keychain: \
                \(Log.describe(error), privacy: .public)
                """)
        }
    }
}

enum SessionDelegateError: Error {
    case nobodySignedIn
    case wrongUser
}
