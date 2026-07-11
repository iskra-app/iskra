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
        guard case let .ready(options) = model.step else {
            Issue.record("Expected to reach the sign-in step, got \(model.step)")
            return
        }
        #expect(options.canUseSingleSignOn || options.supportsPassword)
    }

    @Test("a typo produces a sentence the user can act on")
    func explainsBadAddress() async {
        let model = model()
        model.address = "definitely-not-a-homeserver.invalid"

        await model.findServer()

        #expect(model.step == .enteringAddress)
        // The message must be about the address, because that is what is wrong and
        // what the user can fix.
        #expect(model.problem?.contains("address") == true)
        // And it must not leak protocol vocabulary onto the screen.
        #expect(model.problem?.lowercased().contains("homeserver") == false)
    }

    @Test("an empty address cannot be submitted")
    func requiresAnAddress() {
        let model = model()
        #expect(!model.canContinue)
    }
}
