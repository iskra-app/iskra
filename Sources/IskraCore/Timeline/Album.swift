import Foundation

/// Photos and videos sent together, drawn as one picture made of several — Telegram's album.
///
/// Matrix has no album. Every photo is an event of its own, and the proposal that would tie them
/// together (MSC4274) is a draft no client sends. So the album is decided here, on the receiving
/// side, from what the events do say: the same person, one picture after another with nothing in
/// between, *at nearly the same moment*. Six photos chosen in the picker and sent with one press
/// leave the send queue one after another and land seconds apart; the same six sent over a
/// lunch break are six messages, and stay six.
///
/// The gap is measured between neighbours, not from the first to the last: the queue uploads one
/// file at a time, and on a slow network ten photos sent at once can take a minute to all arrive
/// while no two of them are more than a few seconds apart.
///
/// The album is a row, and the row is its **first** message — what it is called, where it sits,
/// what a reaction, a reply or a pin lands on — carrying all of them in `Message.album`. The first
/// and not the last, because the row's identity must not change as the rest of the album arrives:
/// a row whose ID moved with every upload would be torn down and drawn afresh each time.
///
/// What would break the album breaks it: anything said in between, a date, the unread bar, a
/// sticker or a circle (each of which is a message of its own, not a picture in a set), a reply
/// anywhere but on the first, and a caption anywhere but on the last — that is where this app puts
/// one (`RoomView.send`), and where every client will show it.
public enum Album {
    /// The longest pause between two pictures of the same album.
    public static let gap: TimeInterval = 15

    /// Telegram's limit, and the picker's: ten to an album.
    public static let limit = 10

    /// The rows, with every album folded into its first message.
    public static func grouping(_ rows: [TimelineRow]) -> [TimelineRow] {
        var result: [TimelineRow] = []
        result.reserveCapacity(rows.count)
        var run: [Message] = []

        func flush() {
            guard let first = run.first else { return }
            result.append(.message(run.count == 1 ? first : folded(run)))
            run.removeAll(keepingCapacity: true)
        }

        for row in rows {
            guard case let .message(message) = row, isPicture(message) else {
                flush()
                result.append(row)
                continue
            }
            if let last = run.last, !belongs(message, after: last, in: run) {
                flush()
            }
            run.append(message)
            // A caption closes the album it is under: nothing that comes after it can join.
            if captionOf(message) != nil { flush() }
        }
        flush()
        return result
    }

    /// A photo or an ordinary video — the two things an album is made of.
    static func isPicture(_ message: Message) -> Bool {
        guard !message.isDeleted else { return false }
        switch message.kind {
        case .image: return true
        case let .video(attachment): return !attachment.isVideoNote
        default: return false
        }
    }

    private static func belongs(_ message: Message, after last: Message, in run: [Message]) -> Bool {
        run.count < limit
            && message.senderID == last.senderID
            && message.replyTo == nil
            && message.forwardedFrom == nil
            && abs(message.timestamp.timeIntervalSince(last.timestamp)) <= gap
    }

    private static func captionOf(_ message: Message) -> String? {
        message.captioned?.caption
    }

    /// The first message, wearing the whole album: the last one's caption and its HTML, a delivery
    /// that is only as far along as the least delivered picture, and the read mark if any of them
    /// had it.
    private static func folded(_ run: [Message]) -> Message {
        var lead = run[0]
        lead.album = run
        lead.delivery = run.lazy.compactMap(\.delivery).min(by: { rank($0) < rank($1) }) ?? lead.delivery
        lead.carriesReadMark = run.contains(where: \.carriesReadMark)
        lead.isContinued = run[run.count - 1].isContinued
        let uploads = run.compactMap(\.uploadProgress)
        lead.uploadProgress = uploads.isEmpty ? nil : uploads.reduce(0, +) / Double(uploads.count)
        return lead
    }

    /// Lower is less far along. A failure outranks everything: one photo that did not go is the
    /// album not having gone, and the badge has to say so.
    private static func rank(_ status: DeliveryStatus) -> Int {
        switch status {
        case .failed: 0
        case .sending: 1
        case .sent: 2
        case .read: 3
        }
    }
}

public extension Message {
    /// The album's caption: the last picture's, which is the only one that may have one.
    var albumCaption: String? {
        album?.last?.captioned?.caption
    }

    /// Every message this row stands for — the album's, or just itself.
    var members: [Message] {
        album ?? [self]
    }
}

public extension Array where Element == TimelineRow {
    /// The message with this ID, wherever it is — a row of its own, or a picture inside an album.
    func message(withID id: String) -> Message? {
        for row in self {
            guard let message = row.message else { continue }
            if message.id == id { return message }
            if let inner = message.album?.first(where: { $0.id == id }) { return inner }
        }
        return nil
    }
}
