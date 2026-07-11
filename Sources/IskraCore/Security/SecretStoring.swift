import Foundation

/// Somewhere to keep the user's secrets.
///
/// In the app this is always the Keychain, and there is no configuration that makes
/// it anything else. The protocol exists so that tests can run without one: the
/// data-protection keychain refuses unsigned binaries (`errSecMissingEntitlement`,
/// -34018), and a `swift test` binary is unsigned, so a test that needed the real
/// Keychain could only ever fail for a reason that has nothing to do with the code
/// under test.
public protocol SecretStoring: Sendable {
    func data(for key: String) throws -> Data?
    func set(_ data: Data, for key: String) throws
    func removeItem(for key: String) throws
    func removeAll() throws
}

extension Keychain: SecretStoring {}
