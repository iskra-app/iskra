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
/// The distinction is explicit on purpose. An App Group that silently falls back to
/// the app's own container gives you an app that works perfectly until the first
/// push arrives and then fails somewhere far away from the cause.
public enum StorageMode: Sendable, Equatable {
    case shared(appGroupIdentifier: String, keychainAccessGroup: String)
    case standalone
}

public struct AppEnvironment: Sendable {
    public let storage: StorageMode

    /// Where the OAuth provider sends the user back after they sign in.
    public let oauthRedirectURI: String

    /// Shown to the user on the homeserver's consent screen, so keep it human.
    public let clientName: String

    public init(storage: StorageMode,
                oauthRedirectURI: String = "iskra://oauth-callback",
                clientName: String = "Iskra") {
        self.storage = storage
        self.oauthRedirectURI = oauthRedirectURI
        self.clientName = clientName
    }

    /// The identifier used for both the App Group container and the Keychain access
    /// group.
    ///
    /// One string does both jobs on purpose. An App Group ID is already globally
    /// unique — that is what the mandatory `group.` prefix buys — so it can be used
    /// as a Keychain access group directly, without the `$(AppIdentifierPrefix)`
    /// team-ID dance that a bare access group would need.
    ///
    /// It must be registered under the team's App ID in the developer portal. Do that
    /// and the same identifier is valid on iOS and on macOS; skip it and macOS will
    /// demand a Team-ID-prefixed group instead, and the two platforms diverge.
    public static let appGroupIdentifier = "group.app.iskra"

    /// Shared with the notification and share extensions. Requires the entitlements
    /// in `Apps/project.yml` and the App Group registered in the developer portal.
    public static let shared = AppEnvironment(
        storage: .shared(appGroupIdentifier: appGroupIdentifier,
                         keychainAccessGroup: appGroupIdentifier)
    )

    /// Everything inside the app. Needs no provisioning, and no extension can see it.
    public static let standalone = AppEnvironment(storage: .standalone)

    /// What the app uses today.
    ///
    /// Flip this to `.shared` once the App Group is registered. Until then `.shared`
    /// would crash on launch, by design — see `containerURL`. Note that the switch
    /// moves both the store and the Keychain, so the signed-in user has to sign in
    /// again; there is no migration, and for a messenger whose local state is a cache
    /// of the server's, that is the honest trade rather than a bug.
    public static let `default` = standalone

    /// The Keychain access group, or nil to use the app's own keychain.
    public var keychainAccessGroup: String? {
        switch storage {
        case let .shared(_, group): group
        case .standalone: nil
        }
    }

    /// Root of everything the SDK writes.
    public var containerURL: URL {
        switch storage {
        case let .shared(appGroupIdentifier, _):
            guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else {
                // The entitlement is missing or the App Group is not registered. There
                // is no safe fallback: quietly writing to the app's own container would
                // produce an app that works until a notification arrives.
                preconditionFailure("""
                    App Group "\(appGroupIdentifier)" is unavailable. Either add the entitlement \
                    and register the group for this App ID, or run with StorageMode.standalone.
                    """)
            }
            return url

        case .standalone:
            let url = URL.applicationSupportDirectory.appending(component: "Iskra")
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
    }

    /// Durable Matrix state: crypto store, room state, the send queue.
    /// Encrypted at rest with a passphrase held in the Keychain.
    public func sessionDataURL(forSessionID id: String) -> URL {
        containerURL.appending(component: "Sessions").appending(component: id)
    }

    /// Disposable Matrix caches. The SDK can rebuild these, so the OS may purge them.
    public func sessionCachesURL(forSessionID id: String) -> URL {
        containerURL.appending(component: "Caches").appending(component: id)
    }

    /// The local full-text search index, also encrypted with a Keychain-held key.
    public func searchIndexURL(forSessionID id: String) -> URL {
        containerURL.appending(component: "Search").appending(component: id)
    }
}
