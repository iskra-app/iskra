import Foundation

/// This installation's nostr keypair — the return address on the tunnel.
///
/// Kept in the Keychain, and kept in a Keychain **service of its own**, which is the one decision
/// here worth explaining. The session's service is emptied on the way out — per account by
/// `SessionStore.remove(sessionID:)`, and wholesale by `SessionStore.clear` — and a key that lived
/// there would be regenerated on the next launch, and anybody
/// running a closed bridge (`ALLOWED_PUBKEYS`) would have to add the new one before they could
/// sign in again — through the bridge they can no longer reach. The bridge's address and relay
/// list survive a sign-out in the App Group's defaults, and this survives with them.
///
/// It is not an identity in any social sense: nobody follows it, it posts nothing, and it exists
/// only so that the answer to a request can be addressed back to the device that asked.
public struct TunnelIdentity: Sendable {
    private static let service = "wtf.iskra.transport"
    private static let key = "nostr-secret"

    private let secrets: any SecretStoring

    public init(secrets: any SecretStoring) {
        self.secrets = secrets
    }

    public init(environment: AppEnvironment = .default) {
        self.secrets = Keychain(service: Self.service, accessGroup: environment.keychainAccessGroup)
    }

    /// The keypair, generating one the first time it is asked for.
    public func keypair() throws -> NostrKeypair {
        if let stored = try secrets.data(for: Self.key), stored.count == 32,
           let existing = try? NostrKeypair(secret: stored) {
            return existing
        }
        let fresh = try NostrKeypair.generate()
        try secrets.set(fresh.secret, for: Self.key)
        return fresh
    }

    /// Forget it, and get a new one next time. Not wired to anything yet; here because a key the
    /// user cannot rotate is a key they are stuck with.
    public func forget() throws {
        try secrets.removeItem(for: Self.key)
    }
}
