import Testing
import Foundation
@testable import IskraCore

/// Where the app is willing to place a call from, and where it refuses to.
///
/// Every test here is about a refusal, and that is the point of the file. The dangerous failure in
/// this feature is not a call that will not connect — it is a call that connects to somebody the
/// user never chose, because the app filled in a blank on their behalf. `ElementCallDiscovery`
/// exists to not do that, and this is what holds it to it.
@Suite("Calls")
struct CallTests {

    // MARK: - Reading the server's answer

    @Test("The address the server names is the address used")
    func takesTheServersAnswer() {
        let document = """
        {
          "m.homeserver": { "base_url": "https://matrix-client.example.org" },
          "io.element.call": { "widget_url": "https://call.example.org" }
        }
        """

        let url = ElementCallDiscovery.widgetURL(inWellKnown: Data(document.utf8))

        #expect(url == URL(string: "https://call.example.org"))
    }

    @Test("A server that names no Element Call gets no call button")
    func silenceMeansNoCalls() {
        let document = """
        { "m.homeserver": { "base_url": "https://matrix-client.example.org" } }
        """

        #expect(ElementCallDiscovery.widgetURL(inWellKnown: Data(document.utf8)) == nil)
    }

    /// The whole argument for this feature having no default, pinned.
    ///
    /// It would be very easy, and it would look like a bug fix, for somebody to make this return
    /// `https://call.element.io` when the server says nothing. That would hand the list of
    /// everybody the user talks to — who, with whom, and when — to a third party, which is the
    /// same trade this project already refused when it ported blobatar rather than calling it.
    @Test("Nothing is invented when the server stays silent")
    func inventsNothing() {
        #expect(ElementCallDiscovery.widgetURL(inWellKnown: Data("{}".utf8)) == nil)
        #expect(ElementCallDiscovery.widgetURL(inWellKnown: Data()) == nil)
        #expect(ElementCallDiscovery.widgetURL(inWellKnown: Data("not json at all".utf8)) == nil)
    }

    @Test("A widget_url on plain http is disbelieved rather than humoured")
    func refusesPlainHTTP() {
        let document = """
        { "io.element.call": { "widget_url": "http://call.example.org" } }
        """

        #expect(ElementCallDiscovery.widgetURL(inWellKnown: Data(document.utf8)) == nil)
    }

    @Test("A widget_url that is not a URL at all is nothing")
    func refusesNonsense() {
        let document = """
        { "io.element.call": { "widget_url": 42 } }
        """

        #expect(ElementCallDiscovery.widgetURL(inWellKnown: Data(document.utf8)) == nil)
    }

    // MARK: - The address somebody typed

    @Test("An address typed by hand is held to the same rule as the server's")
    func typedAddressMustBeHTTPS() {
        let defaults = Self.scratchDefaults()

        defaults.set("https://call.example.org", forKey: BetaFeatures.elementCallURLKey)
        #expect(BetaFeatures.elementCallURL(in: defaults) == URL(string: "https://call.example.org"))

        // A typo that leaves the scheme off is nothing, not a call placed in the clear.
        defaults.set("call.example.org", forKey: BetaFeatures.elementCallURLKey)
        #expect(BetaFeatures.elementCallURL(in: defaults) == nil)

        defaults.set("http://call.example.org", forKey: BetaFeatures.elementCallURLKey)
        #expect(BetaFeatures.elementCallURL(in: defaults) == nil)
    }

    @Test("An empty field means the server decides")
    func emptyFieldIsNotAnAddress() {
        let defaults = Self.scratchDefaults()

        #expect(BetaFeatures.elementCallURL(in: defaults) == nil)

        defaults.set("   ", forKey: BetaFeatures.elementCallURLKey)
        #expect(BetaFeatures.elementCallURL(in: defaults) == nil)
    }

    // MARK: - Availability

    /// Both halves are required, and the test says why in its own shape: three of the four
    /// combinations are "no call button".
    @Test("A call needs both an address and a server that carries one")
    func availabilityNeedsBoth() {
        let address = URL(string: "https://call.example.org")

        #expect(CallAvailability(widgetURL: address, serverCarriesCalls: true).isAvailable)
        #expect(!CallAvailability(widgetURL: address, serverCarriesCalls: false).isAvailable)
        #expect(!CallAvailability(widgetURL: nil, serverCarriesCalls: true).isAvailable)
        #expect(!CallAvailability.none.isAvailable)
    }

    // MARK: -

    /// A defaults suite of this test's own, so that running the suite cannot write into the
    /// preferences of whoever is running it.
    private static func scratchDefaults() -> UserDefaults {
        let suite = "moscow.swag.iskra.tests.calls.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}
