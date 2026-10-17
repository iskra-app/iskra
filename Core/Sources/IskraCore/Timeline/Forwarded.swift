import Foundation
import Synchronization

/// Where a forwarded message came from, as the message itself says.
///
/// Matrix has no native forward: a forward is a new message carrying the same words. What marks
/// it as one is `m.forwarded` in its content — MSC2723, taken up again by MSC4553 — an object
/// naming the original's sender, event, room and time. Neither is merged into the spec, and few
/// clients send it; but it is the one shape anybody agrees on, so it is the shape this app writes
/// and reads. Every field is optional, as the MSCs say.
public struct ForwardOrigin: Sendable, Equatable {
    public let senderID: String?
    /// The name the original sender went by when it was forwarded. Not in either MSC's table —
    /// MSC2723 names it as the way to attribute somebody the reader shares no room with — and
    /// used only when it is there.
    public let senderName: String?
    public let eventID: String?
    public let roomID: String?
    public let timestamp: Date?

    public init(senderID: String?, senderName: String? = nil, eventID: String? = nil,
                roomID: String? = nil, timestamp: Date? = nil) {
        self.senderID = senderID
        self.senderName = senderName
        self.eventID = eventID
        self.roomID = roomID
        self.timestamp = timestamp
    }

    /// Who to say it is from: the name, or the Matrix ID, or nobody — "Forwarded" on its own.
    public var displayName: String? {
        if let senderName, !senderName.isEmpty { return senderName }
        return senderID
    }
}

enum Forwarded {
    static let key = "m.forwarded"

    /// The origin an event's content names, read from the event's JSON.
    static func origin(inEventJSON json: String) -> ForwardOrigin? {
        guard let data = json.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = event["content"] as? [String: Any] else { return nil }
        return origin(inContent: content)
    }

    static func origin(inContent content: [String: Any]) -> ForwardOrigin? {
        guard let forwarded = content[key] as? [String: Any] else { return nil }
        let timestamp = (forwarded["origin_server_ts"] as? NSNumber).map {
            Date(timeIntervalSince1970: $0.doubleValue / 1000)
        }
        return ForwardOrigin(senderID: forwarded["sender"] as? String,
                             senderName: forwarded["displayname"] as? String,
                             eventID: forwarded["event_id"] as? String,
                             roomID: forwarded["room_id"] as? String,
                             timestamp: timestamp)
    }

    /// The `m.room.message` content that forwards these words, or nil for a message that is not
    /// words. A forward of a forward points at the original, not at the forward in between — the
    /// MSC's rule, and the reader's: "forwarded from Аня" is what they want to know, not who passed
    /// it on.
    static func content(forwarding message: Message) -> [String: Any]? {
        let msgtype: String
        let body: String
        switch message.kind {
        case let .text(text): (msgtype, body) = ("m.text", text)
        case let .notice(text): (msgtype, body) = ("m.notice", text)
        case let .emote(text): (msgtype, body) = ("m.emote", text)
        default: return nil
        }

        var original: [String: Any] = ["msgtype": msgtype, "body": body]
        if let html = message.formattedBody {
            original["format"] = "org.matrix.custom.html"
            original["formatted_body"] = html
        }

        // Only *that* it is a forward, and when it was first said — never who said it or where.
        // A marked forward goes only into a room that is not encrypted, and the message may well
        // come out of one that is: its author's name and Matrix ID, or an event ID from a private
        // conversation, written where the server can read them, say who was talking and that the
        // conversation exists. Every field but `content` is optional in both MSCs, and a reader
        // with no `sender` draws the plain "Forwarded" — which is what it says here.
        var forwarded: [String: Any] = [:]
        if let date = message.forwardedFrom?.timestamp ?? (message.forwardedFrom == nil ? message.timestamp : nil) {
            forwarded["origin_server_ts"] = Int(date.timeIntervalSince1970 * 1000)
        }
        forwarded["content"] = original

        var content = original
        content[key] = forwarded
        // Nobody is mentioned by passing their words on — and an empty set is what stops the
        // legacy push rules from reading a name in the body as one. MSC4553 asks for it.
        content["m.mentions"] = [:] as [String: Any]
        return content
    }

    /// What each event has been found to say, by event ID — so the JSON of a message is read once
    /// and not on every rebuild of the conversation it is in. An event's content does not change
    /// under its ID; an edit is another event.
    private static let cache = Mutex<[String: ForwardOrigin?]>([:])
    private static let cacheLimit = 4096

    static func origin(eventID: String, json: () -> String?) -> ForwardOrigin? {
        if let known = cache.withLock({ $0[eventID] }) { return known }
        let found = json().flatMap(origin(inEventJSON:))
        cache.withLock { cache in
            if cache.count >= cacheLimit { cache.removeAll(keepingCapacity: true) }
            cache[eventID] = .some(found)
        }
        return found
    }
}
