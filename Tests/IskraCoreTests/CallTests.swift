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

    // MARK: - The LiveKit focus in .well-known

    @Test("A LiveKit focus in rtc_foci counts, next to Element's placeholder entry")
    func findsLiveKitFocus() {
        // nope.chat's document, as served on 2026-10-28: Synapse there answers the SDK's
        // `rtc/transports` with 404, and this list is the only place the focus is announced.
        let document = """
        {
          "m.homeserver": { "base_url": "https://nope.chat" },
          "org.matrix.msc4143.rtc_foci": [
            { "type": "livekit", "livekit_service_url": "https://nope.chat/livekit/jwt" },
            { "type": "nextgen_new_foci_type", "props_for_nextgen_foci": "val" }
          ]
        }
        """

        #expect(ElementCallDiscovery.hasLiveKitFocus(inWellKnown: Data(document.utf8)))
    }

    @Test("No focus, a focus of another kind, or one on plain http is no focus")
    func refusesOtherFoci() {
        let none = #"{ "m.homeserver": { "base_url": "https://example.org" } }"#
        let otherKind = #"{ "org.matrix.msc4143.rtc_foci": [ { "type": "nextgen_new_foci_type" } ] }"#
        let plainHTTP = #"{ "org.matrix.msc4143.rtc_foci": [ { "type": "livekit", "livekit_service_url": "http://example.org/jwt" } ] }"#

        #expect(!ElementCallDiscovery.hasLiveKitFocus(inWellKnown: Data(none.utf8)))
        #expect(!ElementCallDiscovery.hasLiveKitFocus(inWellKnown: Data(otherKind.utf8)))
        #expect(!ElementCallDiscovery.hasLiveKitFocus(inWellKnown: Data(plainHTTP.utf8)))
        #expect(!ElementCallDiscovery.hasLiveKitFocus(inWellKnown: Data("not json".utf8)))
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

    // MARK: - The grey line in the conversation

    @Test("Each kind of call gets its own line, including the kind that did not say")
    func callLinesAreDistinct() {
        let video = Self.event(.callStarted(isVideo: true)).text
        let voice = Self.event(.callStarted(isVideo: false)).text
        let unsaid = Self.event(.callStarted(isVideo: nil)).text
        let declined = Self.event(.callDeclined).text

        #expect(!video.isEmpty)
        #expect(video != voice)
        #expect(!unsaid.isEmpty)
        #expect(declined != unsaid)
    }

    /// Two calls in a row are two calls, and the enum already guarantees it — `people` answers nil
    /// for everything that is not an arrival or a departure, so there is nothing to pool. Pinned
    /// because the guarantee is a `default:` several screens away from these cases, and somebody
    /// adding `people` to a future case would break this without touching this file.
    @Test("Two calls in a row are not collapsed into one line")
    func callsDoNotMerge() {
        let first = RoomEventKind.callStarted(isVideo: nil)
        let second = RoomEventKind.callStarted(isVideo: nil)

        #expect(first.people == nil)
        #expect(first.merged(with: second) == nil)
        #expect(RoomEventKind.callDeclined.merged(with: second) == nil)
    }

    // MARK: - The identity of a ringing call

    /// The bug this prevents is visible and confusing: two ringing calls on the lock screen from
    /// one person, because a retried VoIP push was given a fresh random UUID.
    @Test("One event always names the same call")
    func ringIDIsDerivedNotInvented() {
        let first = RingID.uuid(forEventID: "$abc:matrix.org")
        let second = RingID.uuid(forEventID: "$abc:matrix.org")
        let other = RingID.uuid(forEventID: "$abd:matrix.org")

        #expect(first == second)
        #expect(first != other)
    }

    @Test("The identifier is a well-formed v4 UUID, hash or not")
    func ringIDLooksLikeAUUID() {
        let uuid = RingID.uuid(forEventID: "$abc:matrix.org")
        let bytes = withUnsafeBytes(of: uuid.uuid) { Array($0) }

        #expect(bytes[6] >> 4 == 0x4)
        #expect(bytes[8] >> 6 == 0b10)
    }

    // MARK: - Not shouting over a ringing call

    @Test("A ring the app has taken charge of silences the extension's fallback")
    func ledgerRemembersARing() {
        let defaults = Self.scratchDefaults()

        #expect(!RingLedger.isRinging(eventID: "$one", in: defaults))

        RingLedger.reported(eventID: "$one", in: defaults)
        #expect(RingLedger.isRinging(eventID: "$one", in: defaults))
        // Only that event. A ledger that silenced everything would swallow real messages.
        #expect(!RingLedger.isRinging(eventID: "$two", in: defaults))

        RingLedger.ended(eventID: "$one", in: defaults)
        #expect(!RingLedger.isRinging(eventID: "$one", in: defaults))
    }

    /// The hand-off lasts seconds; the entry must not last for the life of the install. A stale id
    /// left lying about is a genuine notification silenced later for no reason.
    @Test("An entry stops counting once it is old")
    func ledgerForgets() {
        let defaults = Self.scratchDefaults()
        let now = Date()

        RingLedger.reported(eventID: "$one", at: now, in: defaults)

        #expect(RingLedger.isRinging(eventID: "$one", at: now.addingTimeInterval(10), in: defaults))
        #expect(!RingLedger.isRinging(eventID: "$one",
                                      at: now.addingTimeInterval(RingLedger.memory + 1),
                                      in: defaults))
    }

    // MARK: - How long a ring rings

    @Test("A ring is capped however long the caller says")
    func ringingTimeIsCapped() {
        let absurd = Self.ring(expiresAt: Date().addingTimeInterval(3600))
        #expect(absurd.ringingTime(cap: 60) == 60)

        let none = Self.ring(expiresAt: nil)
        #expect(none.ringingTime(cap: 60) == 60)

        // Already past: no negative interval for somebody to schedule a timer with.
        let gone = Self.ring(expiresAt: Date().addingTimeInterval(-10))
        #expect(gone.ringingTime(cap: 60) == 0)
        #expect(gone.hasExpired())
    }

    // MARK: -

    private static func ring(expiresAt: Date?) -> CallRing {
        CallRing(roomID: "!room:matrix.org",
                 eventID: "$one",
                 callerName: "Аня",
                 callerID: "@anna:matrix.org",
                 roomName: "Аня",
                 isDirect: true,
                 isVideo: false,
                 expiresAt: expiresAt)
    }

    private static func event(_ kind: RoomEventKind) -> RoomEvent {
        RoomEvent(id: "$one", kind: kind, timestamp: Date(timeIntervalSince1970: 0))
    }

    /// A defaults suite of this test's own, so that running the suite cannot write into the
    /// preferences of whoever is running it.
    private static func scratchDefaults() -> UserDefaults {
        let suite = "wtf.iskra.tests.calls.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}
