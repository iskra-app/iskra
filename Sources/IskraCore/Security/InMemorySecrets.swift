import Foundation

/// Secrets that last exactly as long as the object holding them.
///
/// For the two places a real Keychain is the wrong answer: tests, because an unsigned test binary
/// cannot open the data-protection keychain at all (`errSecMissingEntitlement`, -34018), and a
/// session against `SignInMockServer`, whose tokens are for a server that stops existing when the
/// app quits — writing them into the Keychain would put them where the *real* account's tokens
/// live, and the next launch would try to restore a session on a port nobody is listening on.
public final class InMemorySecrets: SecretStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]

    public init() {}

    public func data(for key: String) throws -> Data? { lock.withLock { items[key] } }
    public func set(_ data: Data, for key: String) throws { lock.withLock { items[key] = data } }
    public func removeItem(for key: String) throws { lock.withLock { _ = items.removeValue(forKey: key) } }
    public func removeAll() throws { lock.withLock { items.removeAll() } }
}
