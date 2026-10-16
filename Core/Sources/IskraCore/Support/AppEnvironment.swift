import Foundation

/// Where the app keeps its files and its secrets.
///
/// There are two honest answers to this, and the app has to say which one it means
/// rather than discovering it by accident:
///
/// - `.shared` puts the Matrix store in an App Group container and the secrets in a
///   shared Keychain access group. This is what production needs, because the
///   notification extension runs in a *different process* and has to open the same
///   encrypted database and the same session to decrypt a push on device.
///
/// - `.standalone` keeps both inside the app itself. Nothing is shared, so a
///   notification extension could not work — but it needs no provisioning, which is
///   what makes the app runnable on a machine that has not had its App ID configured
///   in the developer portal.
///
/// - `.scratch` puts the store in a directory of the caller's choosing and is for sessions that
///   are not the user's at all — a sign-in against `SignInMockServer`. It keeps them out of both
///   places a real account lives, so that trying the sign-in screen cannot disturb one.
///
/// The distinction is explicit on purpose. An App Group that silently falls back to
/// the app's own container gives you an app that works perfectly until the first
/// push arrives and then fails somewhere far away from the cause.
public enum StorageMode: Sendable, Equatable {
    case shared(appGroupIdentifier: String, keychainAccessGroup: String)
    case standalone
    case scratch(URL)
}

public enum StorageError: Error, Equatable {
    /// The entitlement is missing, or the App Group is not enabled on the App ID, so
    /// the shared container does not exist for this build. The Simulator ignores
    /// provisioning entirely and will happily hide this until you run on a device.
    case appGroupUnavailable(String)
}

public struct AppEnvironment: Sendable {
    public let storage: StorageMode

    /// Where the OAuth provider sends the user back after they sign in.
    ///
    /// **`app.iskra:`, and not `iskra:`, and the difference is the whole of OAuth working.** It was
    /// `iskra://oauth-callback` and matrix.org refused to register the client at all:
    ///
    /// ```
    /// client registration failed: invalid_redirect_uri: invalid redirect_uri
    /// ```
    ///
    /// A homeserver running the authentication service will only accept a private-use URI scheme
    /// that is the *reverse-DNS of the client's own domain* — that is the rule for native apps, and
    /// it exists so that a scheme cannot be claimed by an app that does not own the domain behind
    /// it. A bare `iskra:` belongs to nobody and is refused.
    ///
    /// **So this string is not free to choose: it is `clientUri` spelled backwards.** The domain is
    /// `iskra.swag.moscow`, so the one scheme permitted is `moscow.swag.iskra` — which is also, and
    /// not by accident, the bundle identifier. Change the domain in `oauthConfiguration()` and this
    /// has to change with it, or the client cannot be registered at all.
    ///
    /// The failure is worth recognising on sight, because it happens *before the browser opens* and
    /// therefore looks nothing like a redirect problem: no browser appears, nothing comes back, and
    /// the screen says the sign-in did not complete. `Iskra --probe-signin matrix.org` names it in
    /// one line.
    ///
    /// The scheme is declared in `Apps/project.yml` (`CFBundleURLSchemes`), and the two must agree
    /// or the browser comes back to an app that is not listening. That is a *third* place the same
    /// fact is written down, and all three have to say it.
    public let oauthRedirectURI: String

    /// What the account is told it is letting in — the name on the homeserver's consent screen, and
    /// the name in the user's own list of signed-in sessions afterwards. So it is the app's name as
    /// a person would say it, and not an identifier.
    public let clientName: String

    public init(storage: StorageMode,
                oauthRedirectURI: String = "moscow.swag.iskra:/oauth-callback",
                clientName: String = "Iskra App") {
        self.storage = storage
        self.oauthRedirectURI = oauthRedirectURI
        self.clientName = clientName
    }

    /// The App Group container. Shared files — the encrypted store — live here.
    public static let appGroupIdentifier = "group.moscow.swag.iskra"

    /// What the Share extension opens to hand a message over to the app, which then sends the outbox
    /// the moment it is in front — see `ShareViewController.openApp()`. The same scheme as
    /// `oauthRedirectURI`, declared once in `Apps/project.yml`; the path says nothing the app acts
    /// on, because coming to the front is the whole of the message.
    public static let shareHandoffURL = URL(string: "moscow.swag.iskra:/share")!

    /// The Keychain access group, which is *not* the App Group.
    ///
    /// It would be tidier if one identifier did both jobs, and on iOS an App Group can
    /// indeed serve as a Keychain access group. It does not work here, and the
    /// provisioning profile says exactly why: a Team Provisioning Profile allows
    ///
    ///     keychain-access-groups = ["936RH3UPR3.*", "com.apple.token"]
    ///
    /// and `group.moscow.swag.iskra` does not match `936RH3UPR3.*`. Xcode rejects the
    /// build with "profile doesn't match the entitlements file's value for the
    /// keychain-access-groups entitlement".
    ///
    /// So the Keychain group carries the team prefix, which the wildcard does cover.
    /// The prefix is not hard-coded: Xcode expands `$(AppIdentifierPrefix)` into the
    /// app's Info.plist, and we read it back, so this keeps working if the team ever
    /// changes.
    private static var keychainAccessGroup: String {
        let prefix = Bundle.main.object(forInfoDictionaryKey: "AppIdentifierPrefix") as? String ?? ""
        return prefix + "moscow.swag.iskra.shared"
    }

    /// Shared with the notification and share extensions. Requires the entitlements in
    /// `Apps/project.yml`, the App Group registered *and enabled on the App ID*, and —
    /// on macOS — this machine registered as a device.
    ///
    /// Computed rather than stored: the team prefix comes from `Bundle.main`, which is
    /// the app's bundle, not this package's, and is not knowable at compile time.
    public static var shared: AppEnvironment {
        AppEnvironment(storage: .shared(appGroupIdentifier: appGroupIdentifier,
                                        keychainAccessGroup: keychainAccessGroup))
    }

    /// Everything inside the app. Needs no provisioning, and no extension can see it.
    public static let standalone = AppEnvironment(storage: .standalone)

    /// What the app uses.
    ///
    /// `.shared` needs the entitlements and the App Group enabled on the App ID;
    /// without them the app crashes on launch by design — see `containerURL`.
    /// `.standalone` still works and is what to fall back to if provisioning has to be
    /// taken out of the picture while debugging something else.
    public static var `default`: AppEnvironment { shared }

    /// Who this process is, when two of them are holding the same store.
    ///
    /// The app and the notification extension are separate processes over one SQLite file, and iOS
    /// will happily run both at once — a push arrives while the app is open, which is the ordinary
    /// case, not the corner one. The SDK takes a cross-process lock for that, and the lock needs a
    /// name to say *who is holding it*, so the two must not answer the same thing.
    ///
    /// `Bundle.main` is the natural answer and is already the right one, because inside an extension
    /// `Bundle.main` is the *extension's* bundle. The app says `moscow.swag.iskra`; the extension
    /// says `moscow.swag.iskra.NotificationService`. (This is the same fact that makes
    /// `AppIdentifierPrefix` load-bearing in the extension's own Info.plist — see `CLAUDE.md`.)
    public static var processName: String {
        Bundle.main.bundleIdentifier ?? "moscow.swag.iskra"
    }

    /// The Keychain access group, or nil to use the app's own keychain.
    public var keychainAccessGroup: String? {
        switch storage {
        case let .shared(_, group): group
        case .standalone, .scratch: nil
        }
    }

    /// Root of everything the SDK writes.
    ///
    /// Throws rather than traps when the App Group is unavailable, and the difference
    /// matters more than it looks. There is still **no fallback** — quietly writing to
    /// the app's own container would produce an app that works until the first push
    /// arrives, and that is still forbidden. But the container is first resolved deep
    /// inside `startSignIn`, on an actor, in response to a tap: trapping there kills
    /// the app the moment someone presses "Continue", a long way from the provisioning
    /// mistake that caused it. As an error it travels to `AuthenticationError.storageUnavailable`
    /// and the screen says what is wrong, which is the same refusal made legible.
    public func containerURL() throws -> URL {
        switch storage {
        case let .shared(appGroupIdentifier, _):
            guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else {
                throw StorageError.appGroupUnavailable(appGroupIdentifier)
            }
            return url

        case .standalone:
            let url = URL.applicationSupportDirectory.appending(component: "Iskra")
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url

        case let .scratch(url):
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
    }

    /// Durable Matrix state: crypto store, room state, the send queue.
    /// Encrypted at rest with a passphrase held in the Keychain.
    public func sessionDataURL(forSessionID id: String) throws -> URL {
        try containerURL().appending(component: "Sessions").appending(component: id)
    }

    /// Disposable Matrix caches. The SDK can rebuild these, so the OS may purge them.
    public func sessionCachesURL(forSessionID id: String) throws -> URL {
        try containerURL().appending(component: "Caches").appending(component: id)
    }

    /// The local full-text search index, also encrypted with a Keychain-held key.
    public func searchIndexURL(forSessionID id: String) throws -> URL {
        try containerURL().appending(component: "Search").appending(component: id)
    }
}
