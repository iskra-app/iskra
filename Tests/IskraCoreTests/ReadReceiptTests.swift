import Foundation
import Testing
@testable import IskraCore

/// The ticks under your own messages, and how far up the conversation they reach.
///
/// A Matrix read receipt names one event — the last one the other person got to — and the SDK
/// hangs it on that event alone. Taken literally, that paints one "read" at the bottom of the
/// room and "sent" on everything above it, which is the protocol's answer and not the reader's:
/// they plainly read the rest, that is how they arrived at the bottom.
@Suite("Read receipts")
struct ReadReceiptTests {
    private func message(_ id: String, own: Bool = true, delivery: DeliveryStatus?) -> TimelineRow {
        .message(Message(id: id,
                         kind: .text("…"),
                         senderID: own ? "@me:example.org" : "@a:example.org",
                         senderName: own ? "Я" : "А",
                         senderAvatarURL: nil,
                         isOwn: own,
                         timestamp: Date(timeIntervalSince1970: 0),
                         delivery: delivery,
                         isEdited: false,
                         replyTo: nil,
                         reactions: [],
                         deletedAt: nil))
    }

    private func delivery(_ rows: [TimelineRow], _ id: String) -> DeliveryStatus? {
        for case let .message(message) in rows where message.id == id { return message.delivery }
        return nil
    }

    /// The bug as reported: the mark showed up on the last read message and on nothing else.
    @Test("a receipt at the bottom reads everything above it")
    func readReachesBackwards() {
        let rows = TimelineMapper.withReadPropagated([
            message("m1", delivery: .sent),
            message("m2", delivery: .sent),
            message("m3", delivery: .read),
        ])
        #expect(delivery(rows, "m1") == .read)
        #expect(delivery(rows, "m2") == .read)
        #expect(delivery(rows, "m3") == .read)
    }

    /// And it stops where the receipt stops. Messages sent *after* the other person last looked
    /// are not read, and saying they are is the same bug pointing the other way.
    @Test("messages below the receipt stay unread")
    func newerMessagesStaySent() {
        let rows = TimelineMapper.withReadPropagated([
            message("m1", delivery: .sent),
            message("m2", delivery: .read),
            message("m3", delivery: .sent),
        ])
        #expect(delivery(rows, "m1") == .read)
        #expect(delivery(rows, "m3") == .sent)
    }

    /// Nothing read, nothing changed — a room where the other person has not been back.
    @Test("no receipt leaves every tick alone")
    func nothingReadChangesNothing() {
        let rows = TimelineMapper.withReadPropagated([
            message("m1", delivery: .sent),
            message("m2", delivery: .sent),
        ])
        #expect(delivery(rows, "m1") == .sent)
        #expect(delivery(rows, "m2") == .sent)
    }

    /// A message still in the queue, or one the queue gave up on, is not quietly promoted to
    /// "read" because a later one was — it has not reached the server at all.
    @Test("sending and failed messages are left as they are")
    func unsentMessagesAreNotPromoted() {
        let rows = TimelineMapper.withReadPropagated([
            message("sending", delivery: .sending),
            message("failed", delivery: .failed(.server)),
            message("read", delivery: .read),
        ])
        #expect(delivery(rows, "sending") == .sending)
        #expect(delivery(rows, "failed") == .failed(.server))
    }

    /// Someone else's messages carry no tick at all, and the pass must not invent one.
    @Test("other people's messages are untouched")
    func otherPeopleAreUntouched() {
        let rows = TimelineMapper.withReadPropagated([
            message("theirs", own: false, delivery: nil),
            message("mine", delivery: .read),
        ])
        #expect(delivery(rows, "theirs") == nil)
    }
}
