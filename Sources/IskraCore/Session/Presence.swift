import Foundation

/// What the homeserver is willing to say about where somebody is.
///
/// Matrix's own three states, and the one number that matters: `lastActive`. The app shows
/// "был(а) 5 мин назад" out of that timestamp and out of nothing else — in particular never out of
/// the last message in the conversation, which is a different fact wearing presence's clothes.
/// Somebody who has been reading all morning without typing is not "был(а) в 09:14".
///
/// Every field is optional in the protocol and every field is optional here, because a server that
/// has presence switched off answers this endpoint with `offline` and no timestamp at all — and the
/// right thing to draw for that is *nothing*, not the word "offline". See `TimelineStore.watchPresence`.
public struct Presence: Sendable, Equatable {
    public enum State: String, Sendable, Equatable {
        case online
        /// Idle. The user's client is connected but nobody has touched it for a while.
        case unavailable
        case offline
    }

    public let state: State

    /// When they last did something, as far as the server knows. Nil when it declined to say.
    public let lastActive: Date?

    /// The server's own claim that they are active *right now* — worth more than `state`, which a
    /// client can set by hand and then walk away from.
    public let isCurrentlyActive: Bool

    /// Whether there is anything here worth putting on screen.
    ///
    /// A bare `offline` with no timestamp is what a server with presence disabled returns for
    /// everyone, including people who are demonstrably typing at you. Drawing "не в сети" from it
    /// would be the app stating, confidently, something it has not been told.
    public var isWorthShowing: Bool {
        if isCurrentlyActive || state == .online { return true }
        return lastActive != nil
    }

    public init(state: State, lastActive: Date?, isCurrentlyActive: Bool) {
        self.state = state
        self.lastActive = lastActive
        self.isCurrentlyActive = isCurrentlyActive
    }

    /// Straight from `GET /_matrix/client/v3/presence/{userId}/status`.
    ///
    /// `last_active_ago` is a duration in milliseconds, not an instant, and it is relative to when
    /// the *server* answered — so it is turned into a date here, at the moment the answer arrives,
    /// rather than stored as an age that silently stops ageing.
    init(json: [String: Any], now: Date = .now) {
        state = (json["presence"] as? String).flatMap(State.init(rawValue:)) ?? .offline
        isCurrentlyActive = json["currently_active"] as? Bool ?? false
        // `NSNumber` rather than `Double`: `JSONSerialization` hands back whichever of the two a
        // server's own formatting implies, and `as? Double` on a whole number quietly fails —
        // which reads, all the way up on screen, as a server that declined to answer.
        if let milliseconds = (json["last_active_ago"] as? NSNumber)?.doubleValue {
            lastActive = now.addingTimeInterval(-milliseconds / 1000)
        } else {
            lastActive = nil
        }
    }
}

/// The server would not say: presence is switched off there, or we share no room with this
/// person. Not an error to show anybody — it means "say nothing", and the header does.
public struct PresenceDeclined: Error, Sendable {
    public let status: Int
}
