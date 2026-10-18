import Foundation
import Security
import IskraCore

/// A smoke test for provisioning, run with `Iskra --verify-storage`.
///
/// This exists because the thing most likely to be misconfigured — the App Group and
/// the Keychain access group — is the one thing the test suite cannot touch. `swift
/// test` builds an unsigned binary, and an unsigned binary is refused by the
/// data-protection Keychain outright (`errSecMissingEntitlement`, -34018) no matter
/// what the entitlements say. Only a signed, installed app can answer the question,
/// and until now the only way to ask it was to sign in by hand.
///
/// So the app can be asked directly. It does exactly what signing in does — resolves
/// the shared container, writes a secret, reads it back — and says so.
enum StorageCheck {
    static var wasRequested: Bool {
        CommandLine.arguments.contains("--verify-storage")
    }

    /// Prints what it found and exits. Never returns.
    static func runAndExit() -> Never {
        let environment = AppEnvironment.default

        print("Iskra storage check")
        print("  mode: \(environment.storage)")

        let container: URL
        do {
            container = try environment.containerURL()
        } catch StorageError.appGroupUnavailable(let group) {
            print("  ❌ app group \"\(group)\" is unavailable to this build")
            print("     The entitlement is there, or the build would not have signed — so the")
            print("     group is most likely not enabled on the App ID, and the profile carries")
            print("     no application-groups. The Simulator ignores provisioning and hides this.")
            exit(1)
        } catch {
            print("  ❌ app group container: \(error)")
            exit(1)
        }
        print("  ✅ app group container: \(container.path(percentEncoded: false))")

        guard let accessGroup = environment.keychainAccessGroup else {
            print("  ⚠️  no keychain access group — running standalone, extensions cannot share this")
            exit(0)
        }
        print("  keychain access group: \(accessGroup)")

        // A full round-trip through the real Keychain, in the real access group.
        let keychain = Keychain(service: "wtf.iskra.storagecheck", accessGroup: accessGroup)
        let secret = Data("iskra-storage-check".utf8)

        do {
            try keychain.set(secret, for: "probe")
            let readBack = try keychain.data(for: "probe")
            try keychain.removeItem(for: "probe")

            guard readBack == secret else {
                print("  ❌ keychain returned something other than what was written")
                exit(1)
            }
            print("  ✅ keychain read/write in the shared access group")
        } catch let KeychainError.unexpectedStatus(status) {
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown"
            print("  ❌ keychain refused us: \(status) — \(message)")
            if status == errSecMissingEntitlement {
                print("     The keychain-access-groups entitlement does not cover \(accessGroup).")
                print("     A Team Provisioning Profile allows only <TeamID>.* — see docs/shared-storage.md.")
            }
            exit(1)
        } catch {
            print("  ❌ keychain failed: \(error)")
            exit(1)
        }

        print("\nShared storage is working. The notification extension will be able to read this.")
        exit(0)
    }
}
