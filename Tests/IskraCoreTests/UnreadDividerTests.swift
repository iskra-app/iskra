import Foundation
import Testing
@testable import IskraCore

/// "Unread messages": the bar a room opens on, Telegram-style. It is the SDK's read marker, and the
/// SDK puts it after the last *event* the account read — which can leave it over a join, over
/// nothing, or over your own reply from another device. The bar has to earn its place.
@Suite("Unread divider")
struct UnreadDividerTests {
    private func message(_ id: String, own: Bool = false) -> TimelineRow {
        .message(Message(id: id,
                         kind: .text("…"),
                         senderID: own ? "@me:example.org" : "@a:example.org",
                         senderName: own ? "Я" : "А",
                         senderAvatarURL: nil,
                         isOwn: own,
                         timestamp: Date(timeIntervalSince1970: 0),
                         delivery: own ? .sent : nil,
                         isEdited: false,
                         reactions: []))
    }

    private func event(_ id: String) -> TimelineRow {
        .event(RoomEvent(id: id, kind: .joined(["А"]), timestamp: Date(timeIntervalSince1970: 0)))
    }

    private func day(_ id: String) -> TimelineRow {
        .dayDivider(DayDivider(id: id, date: Date(timeIntervalSince1970: 0)))
    }

    @Test("kept above something somebody else said")
    func keptAboveTheirs() {
        let rows = TimelineMapper.withUnreadDividerIfEarned([message("a"), .unreadDivider, message("b")])
        #expect(rows.map(\.id) == ["a", TimelineRow.unreadDividerID, "b"])
    }

    @Test("dropped at the very end")
    func droppedAtEnd() {
        let rows = TimelineMapper.withUnreadDividerIfEarned([message("a"), .unreadDivider])
        #expect(rows.map(\.id) == ["a"])
    }

    @Test("dropped above only our own words and grey lines")
    func droppedAboveOwn() {
        let rows = TimelineMapper.withUnreadDividerIfEarned(
            [message("a"), .unreadDivider, event("joined"), message("mine", own: true)])
        #expect(!rows.contains(.unreadDivider))
    }

    @Test("kept when something of theirs comes after our reply")
    func keptPastOwn() {
        let rows = TimelineMapper.withUnreadDividerIfEarned(
            [.unreadDivider, message("mine", own: true), message("theirs")])
        #expect(rows.first == .unreadDivider)
    }

    @Test("a date that only introduced an unearned bar goes with it")
    func dayGoesWithBar() {
        let rows = TimelineMapper.withoutEmptyDays(TimelineMapper.withUnreadDividerIfEarned(
            [message("a"), day("today"), .unreadDivider]))
        #expect(rows.map(\.id) == ["a"])
    }

    @Test("a bar gives the row under it its air, as a date does")
    func isDivider() {
        #expect(TimelineRow.unreadDivider.isDivider)
        #expect(day("d").isDivider)
        #expect(!message("m").isDivider)
    }
}
