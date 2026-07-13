import Foundation
import Testing
@testable import IskraCore

/// Matrix carries a place as a `geo:` URI — a string — so sending and receiving a location is
/// parsing, and parsing is where this quietly goes wrong.
@Suite("Locations")
struct LocationTests {
    @Test("a place survives the round trip through a geo: URI")
    func roundTrip() {
        let sent = Location(latitude: 55.755826, longitude: 37.617300)
        let received = Location(geoURI: sent.geoURI)

        #expect(received?.latitude == 55.755826)
        #expect(received?.longitude == 37.617300)
    }

    /// `geo:` may carry an altitude after the coordinates and an accuracy radius after a
    /// semicolon. Neither is anything this app would draw — a pin on a map has no height — so both
    /// are dropped, and the point is that they are dropped rather than parsed into the latitude.
    @Test("altitude and accuracy are dropped, not misread")
    func extrasAreIgnored() {
        let withAltitude = Location(geoURI: "geo:48.858370,2.294481,120")
        #expect(withAltitude?.latitude == 48.858370)
        #expect(withAltitude?.longitude == 2.294481)

        let withAccuracy = Location(geoURI: "geo:48.858370,2.294481;u=35")
        #expect(withAccuracy?.longitude == 2.294481)
    }

    /// The one that matters. A homeserver forwards whatever a client sent, and `MapKit` handed a
    /// latitude of 900 does not complain — it draws nothing, in silence, somewhere off the edge of
    /// the world. Refused here, it becomes an unsupported message, which is what it is.
    @Test("a coordinate off the globe is refused")
    func nonsenseIsRefused() {
        #expect(Location(geoURI: "geo:900,0") == nil)
        #expect(Location(geoURI: "geo:0,181") == nil)
        #expect(Location(geoURI: "geo:not,anumber") == nil)
        #expect(Location(geoURI: "geo:55.75") == nil)
        #expect(Location(geoURI: "") == nil)
    }

    /// Six decimals is about a tenth of a metre — finer than any phone knows where it is, and far
    /// finer than anybody means when they send somebody a place. What is being pinned here is that
    /// the format is fixed-point and not scientific notation: `1e-05` is a valid Double and not a
    /// valid `geo:` URI.
    @Test("the URI is written as plain decimals")
    func formatIsDecimal() {
        let tiny = Location(latitude: 0.000012, longitude: -0.000034)
        #expect(tiny.geoURI == "geo:0.000012,-0.000034")
    }
}
