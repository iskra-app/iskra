import Foundation
import Security

public enum KeychainError: Error, Equatable {
    case unexpectedStatus(OSStatus)
    case dataCorrupted
}

/// A thin, deliberately boring wrapper over the data-protection Keychain.
///
/// Three choices here are load-bearing and should not be "simplified" later:
///
/// 1. `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` — the notification
///    extension has to decrypt messages that arrive while the phone is locked, so
///    the secrets must be readable after first unlock. `ThisDeviceOnly` then makes
///    sure they are never carried off the device in an iCloud Keychain sync or an
///    unencrypted backup.
///
/// 2. `kSecUseDataProtectionKeychain` — on macOS this opts us into the same
///    keychain semantics as iOS. Without it, access groups and accessibility
///    attributes quietly do nothing on the Mac.
///
/// 3. `kSecAttrAccessGroup` — how the app and its extensions see the same items.
public struct Keychain: Sendable {
    private let service: String
    private let accessGroup: String

    public init(service: String = "app.iskra.session", accessGroup: String) {
        self.service = service
        self.accessGroup = accessGroup
    }

    private func baseQuery(for key: String) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key,
            kSecAttrAccessGroup: accessGroup,
            kSecUseDataProtectionKeychain: true
        ]
    }

    public func set(_ data: Data, for key: String) throws {
        var query = baseQuery(for: key)

        // Upsert. Try to update first, because SecItemAdd on an existing item fails
        // with errSecDuplicateItem rather than overwriting.
        let updates: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, updates as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(updateStatus)
        }

        query.merge(updates) { current, _ in current }
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError.unexpectedStatus(addStatus)
        }
    }

    public func data(for key: String) throws -> Data? {
        var query = baseQuery(for: key)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { throw KeychainError.dataCorrupted }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    public func removeItem(for key: String) throws {
        let status = SecItemDelete(baseQuery(for: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Used when signing out. Everything we hold is per-session, so it all goes.
    public func removeAll() throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccessGroup: accessGroup,
            kSecUseDataProtectionKeychain: true
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}
