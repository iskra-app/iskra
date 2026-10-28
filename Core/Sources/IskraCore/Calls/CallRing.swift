import Foundation
import CryptoKit

/// One incoming call, as much as is known about it.
///
/// A value type with no SDK in it, because of where it has to travel: a VoIP push arrives in the
/// app's process and the thing that must be told about it is CallKit, which lives in
/// `IskraFeatures`. Everything below is either in the push already or was decrypted out of one
/// event.
public struct CallRing: Sendable, Equatable {
    public let roomID: String

    /// The `m.rtc.notification` event. Also the identifier used to decline, and the seed the call's
    /// CallKit UUID is derived from — see `RingID`.
    public let eventID: String

    /// Who is calling, as a person would say it: the name they chose, or their Matrix ID.
    public let callerName: String
    public let callerID: String

    /// The room's name. Shown instead of the caller in a group, where "Аня" is true and
    /// "Аня" alone is not what the reader needs to decide whether to answer.
    public let roomName: String

    /// Whether this is a personal chat, which decides which of the two names above is shown.
    public let isDirect: Bool

    public let isVideo: Bool

    /// When the ring stops being a ring, as the caller's client said. Nil where it did not say.
    public let expiresAt: Date?

    public init(roomID: String,
                eventID: String,
                callerName: String,
                callerID: String,
                roomName: String,
                isDirect: Bool,
                isVideo: Bool,
                expiresAt: Date?) {
        self.roomID = roomID
        self.eventID = eventID
        self.callerName = callerName
        self.callerID = callerID
        self.roomName = roomName
        self.isDirect = isDirect
        self.isVideo = isVideo
        self.expiresAt = expiresAt
    }

    /// The name to put on the lock screen.
    public var displayTitle: String {
        isDirect ? callerName : roomName
    }

    public func hasExpired(at moment: Date = Date()) -> Bool {
        guard let expiresAt else { return false }
        return moment >= expiresAt
    }

    /// How long is left to ring, capped.
    ///
    /// Capped because the expiry comes from somebody else's client and a phone that rings for an
    /// hour is a phone that gets the app deleted. Floored at nothing, so an expiry already in the
    /// past does not become a negative interval somebody schedules a timer with.
    public func ringingTime(from moment: Date = Date(), cap: TimeInterval = 60) -> TimeInterval {
        guard let expiresAt else { return cap }
        return max(0, min(cap, expiresAt.timeIntervalSince(moment)))
    }
}

/// What came back when a ring was looked up.
public enum RingOutcome: Sendable {
    /// Ring it.
    case ring(CallRing)

    /// There is nothing to ring about — and the caller **still has to report the call to CallKit
    /// and then end it**. See `IncomingCallCenter`; this is not permission to skip the report.
    case over(RingEnded, CallRing?)

    /// Nobody is signed in on this device.
    case notSignedIn

    /// It could not be looked up at all. Same obligation as `.over`.
    case failed(String)
}

/// Why a ring is not ringing.
///
/// Each maps to a `CXCallEndedReason`, and the mapping is the reason they are distinguished at
/// all: "you missed this" and "you took it on your iPad" are the same non-event to the app and two
/// entirely different lines in somebody's call history.
public enum RingEnded: Sendable, Equatable {
    /// The caller's client said the ring had expired, and it has.
    case expired
    /// Somebody answered on another of this account's devices.
    case answeredElsewhere
    /// Somebody declined on another of this account's devices.
    case declinedElsewhere
    /// The call itself is finished — nobody is in it any more.
    case alreadyOver
    /// The event turned out not to be a ring at all. A notification the gateway should not have
    /// sent to the VoIP pusher, which means the rule or the gateway filter is wrong.
    case notACall
}

/// The UUID a call is known by, derived from the event rather than invented.
///
/// **Not random, and that is load-bearing.** A VoIP push can be delivered more than once for one
/// ring — a retry, or a second notify from the homeserver — and a fresh UUID each time means two
/// ringing calls on the lock screen from one person. Reporting the same UUID twice is a no-op to
/// CallKit, so deriving it from the event id makes duplicates free.
///
/// It also survives the process dying: anything that needs to end this call later can work the
/// UUID out again from the event id alone, with no table to have lost.
public enum RingID {
    public static func uuid(forEventID eventID: String) -> UUID {
        // CryptoKit's, not ours. Nothing here is protecting anything — this is a hash used to
        // spread event ids evenly over 128 bits — but the rule in `CLAUDE.md` about not
        // reimplementing cryptography does not have an exemption for the easy cases, and it
        // should not: a hand-rolled SHA-256 in this file would be the first one.
        var digest = Array(SHA256.hash(data: Data(eventID.utf8)))

        // RFC 4122: version 4 in the high nibble of byte 6, variant 10 in the top bits of byte 8.
        // The bytes are a hash rather than randomness, but the *shape* still has to be a valid
        // UUID or anything that parses one is entitled to refuse it.
        digest[6] = (digest[6] & 0x0F) | 0x40
        digest[8] = (digest[8] & 0x3F) | 0x80

        let bytes = (digest[0], digest[1], digest[2], digest[3],
                     digest[4], digest[5], digest[6], digest[7],
                     digest[8], digest[9], digest[10], digest[11],
                     digest[12], digest[13], digest[14], digest[15])
        return UUID(uuid: bytes)
    }
}
