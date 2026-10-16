import Foundation

/// A place on the map, as a message carries it.
///
/// Matrix puts the coordinates in a `geo:` URI — the RFC 5870 one, the same scheme a browser
/// honours — rather than in two numbers of its own. So the wire format is a *string*, and this
/// type is the two ends of parsing it: what comes out of one somebody sent, and what goes into
/// one we are about to send.
///
/// It carries no altitude and no accuracy radius. `geo:` can express both — `geo:55.7,37.6,150`
/// and `;u=35` — and nothing in this app would draw either: a bubble shows a pin on a map, and a
/// pin does not have a height. They are parsed away rather than mangled into the latitude.
public struct Location: Sendable, Equatable {
    public let latitude: Double
    public let longitude: Double

    /// What the sender called it, where they said anything. Not an address: nothing here does
    /// reverse geocoding, and inventing a street name for a pin somebody dropped would be the app
    /// putting words in their mouth.
    public let name: String?

    /// Set when this is somebody's location *as it moves* — a live share (MSC3489), the last point
    /// of it. Nil for a pin dropped once.
    public var live: LiveSpan?

    /// What a live share says about itself besides where it last was.
    public struct LiveSpan: Sendable, Equatable {
        /// Whether the sharer still says it is on — they can stop it before its time.
        public let isLive: Bool
        /// When it stops by itself.
        public let until: Date
        /// When the last point arrived; nil while none has.
        public let updatedAt: Date?

        public init(isLive: Bool, until: Date, updatedAt: Date?) {
            self.isLive = isLive
            self.until = until
            self.updatedAt = updatedAt
        }

        /// Still moving on the map: switched on, and not past its time.
        public func isActive(now: Date = .now) -> Bool {
            isLive && until > now
        }

        /// Whether there is a point to show at all — a share just started has none yet.
        public var hasPosition: Bool { updatedAt != nil }
    }

    public init(latitude: Double, longitude: Double, name: String? = nil) {
        self.latitude = latitude
        self.longitude = longitude
        self.name = name
    }

    /// The `geo:` URI Matrix wants. Six decimal places is about a tenth of a metre, which is
    /// finer than any phone knows where it is and far finer than anybody means when they send
    /// somebody a place.
    public var geoURI: String {
        String(format: "geo:%.6f,%.6f", latitude, longitude)
    }

    /// Reads one back. Nil for anything that is not a location this app can put on a map —
    /// a malformed URI, a coordinate off the globe, a scheme that is not `geo:`.
    ///
    /// The bounds check is not pedantry. A homeserver will forward whatever a client sent, and
    /// `MapKit` handed a latitude of 900 does not throw: it draws nothing, in silence, somewhere
    /// off the edge of the world. Refusing it here turns that into an unsupported message, which
    /// is what it is.
    public init?(geoURI: String, name: String? = nil) {
        let body = geoURI.hasPrefix("geo:") ? String(geoURI.dropFirst(4)) : geoURI

        // "55.75,37.61" — and possibly ",150" for altitude or ";u=35" for accuracy after it.
        // Both are dropped: see the note on the type.
        let coordinates = body.split(separator: ";").first ?? ""
        let parts = coordinates.split(separator: ",")

        guard parts.count >= 2,
              let latitude = Double(parts[0]),
              let longitude = Double(parts[1]),
              (-90...90).contains(latitude),
              (-180...180).contains(longitude) else { return nil }

        self.latitude = latitude
        self.longitude = longitude
        self.name = name
    }
}
