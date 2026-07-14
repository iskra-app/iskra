import Foundation
import Testing
@testable import IskraCore

/// The date headers across a conversation, and the days they are allowed to announce.
///
/// A header is a *promise* — "here begins yesterday" — and the app breaks it whenever it drops
/// everything that was under one. It drops a great deal: a picture change, a power level, a topic
/// edit, an event it could not parse. The SDK is entitled to put a divider before any of those,
/// because to the SDK they are the day's contents. To the reader they are nothing, and the header
/// over them is a day of messages that never existed.
@Suite("Day dividers")
struct DayDividerTests {
    private func divider(_ id: String) -> TimelineRow {
        .dayDivider(DayDivider(id: id, date: Date(timeIntervalSince1970: 0)))
    }

    private func message(_ id: String) -> TimelineRow {
        .message(Message(id: id,
                         kind: .text("…"),
                         senderID: "@a:example.org",
                         senderName: "А",
                         senderAvatarURL: nil,
                         isOwn: false,
                         timestamp: Date(timeIntervalSince1970: 0),
                         delivery: nil,
                         isEdited: false,
                         replyTo: nil,
                         reactions: [],
                         deletedAt: nil))
    }

    private func event(_ id: String) -> TimelineRow {
        .event(RoomEvent(id: id,
                         kind: .joined(["А"]),
                         timestamp: Date(timeIntervalSince1970: 0)))
    }

    /// The bug as reported: "вчера" over a day on which nobody said anything.
    @Test("a day with nothing under it loses its header")
    func emptyDayGoesAway() {
        let rows = TimelineMapper.withoutEmptyDays([divider("yesterday"), divider("today"), message("m")])
        #expect(rows.map(\.id) == ["today", "m"])
    }

    /// And the day that does have something keeps it. This is the half that a fix which simply
    /// deleted dividers would break, and it would be a worse bug than the one it cured.
    @Test("a day with messages keeps its header")
    func fullDayStays() {
        let rows = TimelineMapper.withoutEmptyDays([divider("d"), message("m1"), message("m2")])
        #expect(rows.map(\.id) == ["d", "m1", "m2"])
    }

    /// A day on which nobody spoke but somebody *arrived* is a day that happened. The grey line
    /// is content: it is the answer to "what went on here", and its header introduces it.
    @Test("a day with only a grey line keeps its header")
    func eventOnlyDayStays() {
        let rows = TimelineMapper.withoutEmptyDays([divider("d"), event("e")])
        #expect(rows.map(\.id) == ["d", "e"])
    }

    /// A header at the very end of the list has nothing under it *yet* — and "yet" is not
    /// something the reader can see. It is a promise of messages that are not there.
    @Test("a header at the end of the conversation is not shown")
    func trailingDividerGoesAway() {
        let rows = TimelineMapper.withoutEmptyDays([message("m"), divider("tomorrow")])
        #expect(rows.map(\.id) == ["m"])
    }

    /// Several empty days in a row — which is what a page of history made entirely of avatar
    /// changes looks like — collapse to the one that has something to say.
    @Test("only the day that has something survives a run of empty ones")
    func onlyTheLivingDaySurvives() {
        let rows = TimelineMapper.withoutEmptyDays([divider("mon"),
                                                    divider("tue"),
                                                    divider("wed"),
                                                    message("m"),
                                                    divider("thu")])
        #expect(rows.map(\.id) == ["wed", "m"])
    }

    /// Nothing at all is still nothing. An empty room does not get a header saying so.
    @Test("an empty conversation has no headers")
    func nothingStaysNothing() {
        #expect(TimelineMapper.withoutEmptyDays([]).isEmpty)
        #expect(TimelineMapper.withoutEmptyDays([divider("d")]).isEmpty)
    }
}
