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

    /// What the app uses today. Becomes `.shared` the moment the notification
    /// extension lands and the App Group is registered for the team's App ID.
    public static let `default` = AppEnvironment(storage: .standalone)

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
