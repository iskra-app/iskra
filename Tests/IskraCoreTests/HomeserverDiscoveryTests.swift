import Testing
import Foundation
@testable import IskraCore

/// Stands in for the Keychain.
///
/// Not a convenience: a `swift test` binary is unsigned, and the data-protection
/// keychain answers unsigned callers with `errSecMissingEntitlement` (-34018) no
/// matter what they ask for. Without this, every test below would fail for a reason
/// that has nothing to do with Matrix.
private final class InMemorySecrets: SecretStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]

    func data(for key: String) throws -> Data? {
        lock.withLock { items[key] }
    }

    func set(_ data: Data, for key: String) throws {
        lock.withLock { items[key] = data }
    }

    func removeItem(for key: String) throws {
        lock.withLock { _ = items.removeValue(forKey: key) }
    }

    func removeAll() throws {
        lock.withLock { items.removeAll() }
    }
}

/// Talks to a real homeserver over the real network.
///
/// This is the test that proves the lower half of the app is wired up: it builds a
/// `Client` across the FFI, creates an encrypted store on disk, performs well-known
/// discovery, and reads back how the server lets people in. If sign-in breaks, it
/// breaks here first.
@Suite(.tags(.network))
struct HomeserverDiscoveryTests {
    private func service() -> AuthenticationService {
        AuthenticationService(environment: AppEnvironment(storage: .standalone),
                              sessionStore: SessionStore(secrets: InMemorySecrets()))
    }

    @Test("matrix.org is found and offers a way to sign in")
    func discoversMatrixOrg() async throws {
        let service = service()

        let options = try await service.startSignIn(homeserverAddress: "matrix.org")

        // Whatever it offers, it must offer something, or nobody could sign in at all.
        #expect(options.canUseSingleSignOn || options.supportsPassword)
        #expect(options.resolvedHomeserverURL.contains("matrix.org"))

        await service.cancelSignIn()
    }

    @Test("a domain that is not a homeserver is reported as not found")
    func rejectsNonHomeserver() async throws {
        let service = service()

        do {
            _ = try await service.startSignIn(homeserverAddress: "example.com")
            Issue.record("example.com is not a homeserver, so this should have thrown")
        } catch AuthenticationError.homeserverNotFound {
            // Correct: and specifically *this* error, not a storage failure wearing
            // its clothes.
        }
    }
}

extension Tag {
    @Tag static var network: Self
}
