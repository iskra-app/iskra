import Testing
import Foundation
@testable import IskraCore

/// The one part of incoming verification that can be tested at all, and — not by coincidence — the
/// part where a mistake is a security bug rather than an annoyance.
///
/// Be exact about what this does *not* cover. Everything past the decision to show the sheet runs
/// through the SDK's `SessionVerificationController`, which needs a live `Client`, a homeserver and
/// a second device signed in to the same account. `swift test` builds an unsigned binary with none
/// of those, so the emoji, the approval and the trust that follows are verified on real devices and
/// nowhere else. Saying so here is better than a test that pretends otherwise.
///
/// What *is* here is the gate: which requests are put in front of the user at all. Both refusals it
/// makes are load-bearing, and both would be easy to delete in good faith one afternoon.
@Suite("Which verification requests reach the user")
struct VerificationTests {
    private static let me = "@boris:matrix.org"

    private func request(from senderID: String = me,
                         device: String = "ABCDEFGH") -> VerificationStore.IncomingRequest {
        VerificationStore.IncomingRequest(flowID: "flow",
                                          senderID: senderID,
                                          deviceID: device,
                                          deviceName: "iPhone")
    }

    @Test("a device of your own, when nothing else is happening, is worth asking about")
    func ownDeviceIsShown() {
        #expect(VerificationStore.shouldShow(request(), to: Self.me, while: .idle))
    }

    /// The one that matters. A verification request from *another user* is a different question with
    /// a different meaning — it asks whether that person is who they say they are, not whether this
    /// phone is yours — and Iskra has no screen for it. Were it to fall through to the incoming
    /// sheet, the user would be shown "this device has just signed in to your account" about a
    /// device belonging to somebody else entirely, and the button they would press says "it's me".
    @Test("somebody else's request is not dressed up as your own device")
    func anotherUsersRequestIsIgnored() {
        #expect(!VerificationStore.shouldShow(request(from: "@eve:matrix.org"), to: Self.me, while: .idle))
    }

    /// A second request arriving while the first is on screen must not quietly replace the name
    /// under the buttons. Whoever is second waits; the user answers the device they actually read.
    @Test("a second request does not swap the device out from under the buttons")
    func aSecondRequestWaits() {
        let steps: [VerificationStore.Step] = [
            .asked, .negotiating, .waitingForOtherDevice, .comparing(["🐶"]), .succeeded, .failed, .declined, .refused
        ]

        for step in steps {
            #expect(!VerificationStore.shouldShow(request(device: "ZZZZZZZZ"), to: Self.me, while: step),
                    "a request arriving during \(step) should not have been shown")
        }
    }
}
