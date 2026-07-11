import Foundation

/// The identifiers and locations that the app, the notification extension and the
/// share extension all have to agree on.
///
/// The notification extension has to decrypt messages on device, which means it
/// needs the same Matrix session and the same encrypted database as the app. The
/// only way to share those across processes is an App Group container (for files)
/// and a Keychain access group (for secrets), so both are declared here once and
/// injected everywhere else.
public struct AppEnvironment: Sendable {
    /// App Group container shared by the app and its extensions. The Matrix store
    /// lives here, *not* in the app's private container, or the notification
    /// extension would not be able to open it.
    public let appGroupIdentifier: String

    /// Keychain access group shared by the app and its extensions.
    public let keychainAccessGroup: String

    /// Where the OAuth provider sends the user back after they sign in.
    public let oauthRedirectURI: String

    /// Shown to the user on the homeserver's consent screen, so keep it human.
    public let clientName: String

    public init(appGroupIdentifier: String,
                keychainAccessGroup: String,
                oauthRedirectURI: String,
                clientName: String) {
        self.appGroupIdentifier = appGroupIdentifier
        self.keychainAccessGroup = keychainAccessGroup
        self.oauthRedirectURI = oauthRedirectURI
        self.clientName = clientName
    }

    public static let `default` = AppEnvironment(
        appGroupIdentifier: "group.app.iskra",
        keychainAccessGroup: "app.iskra.shared",
        oauthRedirectURI: "iskra://oauth-callback",
        clientName: "Iskra"
    )

    /// Root of the shared container. Everything the SDK writes goes under here.
    public var sharedContainerURL: URL {
        guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else {
            // A missing App Group container means the entitlement is wrong. There is
            // no sane fallback: writing to the private container instead would give
            // us an app that works until the first notification arrives and then
            // fails in a way that is very hard to trace back to here.
            preconditionFailure("App Group \(appGroupIdentifier) is not available. Check the target's entitlements.")
        }
        return url
    }

    /// Durable Matrix state: crypto store, room state, the send queue.
    /// Encrypted at rest with a passphrase held in the Keychain.
    public func sessionDataURL(forSessionID id: String) -> URL {
        sharedContainerURL.appending(component: "Sessions").appending(component: id)
    }

    /// Disposable Matrix caches. The SDK can rebuild these, so the OS may purge them.
    public func sessionCachesURL(forSessionID id: String) -> URL {
        sharedContainerURL.appending(component: "Caches").appending(component: id)
    }

    /// The local full-text search index, also encrypted with a Keychain-held key.
    public func searchIndexURL(forSessionID id: String) -> URL {
        sharedContainerURL.appending(component: "Search").appending(component: id)
    }
}
