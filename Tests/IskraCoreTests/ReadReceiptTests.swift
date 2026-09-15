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

    private func marked(_ rows: [TimelineRow]) -> [String] {
        rows.compactMap { row in
            guard case let .message(message) = row, message.carriesReadMark else { return nil }
            return message.id
        }
    }

    private func readAt(_ rows: [TimelineRow], _ id: String) -> Date? {
        for case let .message(message) in rows where message.id == id { return message.readAt }
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

    /// The second bug, and the one that was actually reported: you write, they answer. Their receipt sits
    /// on *their* reply, not on anything of yours, so nothing in the list carries `.read` at all
    /// and every message you sent kept one tick for good. `readUpTo` is how many rows the receipt
    /// covers, counted where the events are still visible.
    @Test("a receipt on somebody else's message reads your messages above it")
    func receiptOnTheirMessageReachesBackwards() {
        let rows = TimelineMapper.withReadPropagated([
            message("mine1", delivery: .sent),
            message("mine2", delivery: .sent),
            message("theirs", own: false, delivery: nil),
        ], readUpTo: 3)

        #expect(delivery(rows, "mine1") == .read)
        #expect(delivery(rows, "mine2") == .read)
        #expect(delivery(rows, "theirs") == nil)
    }

    /// The watermark is a line, not a blanket: what came after it is not read.
    @Test("messages below the foreign watermark stay sent")
    func messagesBelowTheForeignWatermarkStaySent() {
        let rows = TimelineMapper.withReadPropagated([
            message("old", delivery: .sent),
            message("theirs", own: false, delivery: nil),
            message("new", delivery: .sent),
        ], readUpTo: 2)

        #expect(delivery(rows, "old") == .read)
        #expect(delivery(rows, "new") == .sent)
    }

    /// A watermark covering nothing changes nothing — the state of a room where the other person
    /// has not looked at it yet, which is the one case where one tick is the truth.
    @Test("an empty watermark leaves every tick alone")
    func emptyWatermarkChangesNothing() {
        let rows = TimelineMapper.withReadPropagated([
            message("m1", delivery: .sent),
            message("m2", delivery: .sent),
        ], readUpTo: 0)

        #expect(delivery(rows, "m1") == .sent)
        #expect(delivery(rows, "m2") == .sent)
    }

    /// The watermark does not promote what never left: a message still in flight under a receipt
    /// that arrived for the messages around it is sending, not read.
    @Test("the foreign watermark leaves unsent messages alone")
    func foreignWatermarkSpareUnsent() {
        let rows = TimelineMapper.withReadPropagated([
            message("sending", delivery: .sending),
            message("failed", delivery: .failed(.server)),
            message("sent", delivery: .sent),
        ], readUpTo: 3)

        #expect(delivery(rows, "sending") == .sending)
        #expect(delivery(rows, "failed") == .failed(.server))
        #expect(delivery(rows, "sent") == .read)
    }

    // MARK: - Where the eye goes, and what it can say

    /// The whole conversation being read is one fact, and the screen should state it once.
    @Test("the eye goes on the newest read message and nowhere else")
    func onlyTheNewestReadMessageIsMarked() {
        let rows = TimelineMapper.withReadPropagated([
            message("m1", delivery: .sent),
            message("m2", delivery: .sent),
            message("m3", delivery: .read),
        ])

        #expect(marked(rows) == ["m3"])
        // And the others are still read — it is the mark that moved, not the fact.
        #expect(delivery(rows, "m1") == .read)
    }

    /// The mark follows the newest *read* message, not the newest one: a message still on its way
    /// out underneath it must not take "read" off the conversation.
    @Test("a message still in flight does not take the mark")
    func unsentMessagesDoNotStealTheMark() {
        let rows = TimelineMapper.withReadPropagated([
            message("read", delivery: .read),
            message("sending", delivery: .sending),
        ])

        #expect(marked(rows) == ["read"])
    }

    /// Nobody has read anything, so nothing wears the mark.
    @Test("an unread conversation has no mark in it")
    func nothingReadIsNotMarked() {
        let rows = TimelineMapper.withReadPropagated([
            message("m1", delivery: .sent),
            message("m2", delivery: .sent),
        ])

        #expect(marked(rows).isEmpty)
    }

    /// Somebody else's message never wears it, however recently it was read.
    @Test("the mark is only ever on your own")
    func theirMessagesAreNeverMarked() {
        let rows = TimelineMapper.withReadPropagated([
            message("mine", delivery: .read),
            message("theirs", own: false, delivery: nil),
        ])

        #expect(marked(rows) == ["mine"])
    }

    /// The second half of the complaint: the menu had no moment to show, because the receipt's
    /// timestamp lives on the event the *reader* got to — theirs — and it was thrown away with it.
    @Test("the watermark's moment reaches the message it is about")
    func theWatermarkCarriesItsMoment() {
        let caughtUp = Date(timeIntervalSince1970: 1_700_000_000)
        let rows = TimelineMapper.withReadPropagated([
            message("mine1", delivery: .sent),
            message("mine2", delivery: .sent),
            message("theirs", own: false, delivery: nil),
        ], readUpTo: 3, at: caughtUp)

        #expect(marked(rows) == ["mine2"])
        #expect(readAt(rows, "mine2") == caughtUp)
        // And no further down: when they read *that* one, nobody knows.
        #expect(readAt(rows, "mine1") == nil)
    }

    /// A receipt is allowed to arrive with no timestamp on it. Then the mark is still right and
    /// the menu still says nothing, which is the whole of what is known.
    @Test("a watermark without a moment marks the message and invents nothing")
    func aMomentlessWatermarkInventsNothing() {
        let rows = TimelineMapper.withReadPropagated([
            message("mine", delivery: .sent),
            message("theirs", own: false, delivery: nil),
        ], readUpTo: 2, at: nil)

        #expect(marked(rows) == ["mine"])
        #expect(readAt(rows, "mine") == nil)
    }
}
