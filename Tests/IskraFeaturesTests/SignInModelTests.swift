import Testing
import Foundation
@testable import IskraCore
@testable import IskraFeatures

private final class InMemorySecrets: SecretStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]

    func data(for key: String) throws -> Data? { lock.withLock { items[key] } }
    func set(_ data: Data, for key: String) throws { lock.withLock { items[key] = data } }
    func removeItem(for key: String) throws { lock.withLock { _ = items.removeValue(forKey: key) } }
    func removeAll() throws { lock.withLock { items.removeAll() } }
}

extension Tag {
    @Tag static var network: Self
}

/// Drives the sign-in screen's model directly — the same object the "Continue" button
/// calls, with the same arguments. Everything between the tap and the homeserver is
/// under test here; only the literal SwiftUI button press is not.
@MainActor
@Suite(.tags(.network))
struct SignInModelTests {
    private func model() -> SignInModel {
        let authentication = AuthenticationService(environment: AppEnvironment(storage: .standalone),
                                                   sessionStore: SessionStore(secrets: InMemorySecrets()))
        return SignInModel(authentication: authentication) { _ in
            Issue.record("Nothing here should reach a signed-in session")
        }
    }

    @Test("typing a real server and continuing offers a way in")
    func findsRealServer() async {
        let model = model()
        model.address = "matrix.org"

        #expect(model.canContinue)

        await model.findServer()

        #expect(model.problem == nil)
        guard case let .found(options) = model.step else {
            Issue.record("Expected to reach the sign-in step, got \(model.step)")
            return
        }
        #expect(options.canUseSingleSignOn || options.supportsPassword)
    }

    @Test("a typo produces a sentence the user can act on")
    func explainsBadAddress() async throws {
        let model = model()
        model.address = "definitely-not-a-homeserver.invalid"

        await model.findServer()

        #expect(model.step == .enteringAddress)

        let problem = try #require(model.problem.map { String(localized: $0) })
        // The message must be about the address, because that is what is wrong and
        // what the user can fix.
        #expect(problem.contains("address"))
        // And it must not leak protocol vocabulary onto the screen.
        #expect(!problem.lowercased().contains("homeserver"))
        // A block fails the same way a typo does, so the bridge is offered — where it is off.
        #expect(model.canTryBridge == !TunnelSettings.isEnabled())
    }

    /// The field starts empty — no server is chosen for anybody — and an empty one, or one of
    /// spaces, cannot be submitted.
    @Test("the server starts empty, and an empty one cannot be submitted")
    func requiresAnAddress() {
        let model = model()
        #expect(model.address.isEmpty)
        #expect(!model.canContinue)

        model.address = "  "
        #expect(!model.canContinue)
    }

    @Test("the server is shown without its scheme or a trailing slash")
    func serverName() {
        let model = model()
        model.address = "https://example.org/"
        #expect(model.serverName == "example.org")
    }
}
