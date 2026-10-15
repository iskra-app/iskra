import Foundation
import Testing
@testable import IskraCore

/// Where a run of one person's messages ends — the bubble that wears the face (`Message.isContinued`).
@Suite("Run ends")
struct RunEndTests {
    private func message(_ id: String, continuation: Bool = false) -> TimelineRow {
        .message(Message(id: id,
                         kind: .text("…"),
                         senderID: "@a:example.org",
                         senderName: "А",
                         senderAvatarURL: nil,
                         isOwn: false,
                         timestamp: Date(timeIntervalSince1970: 0),
                         delivery: nil,
                         isEdited: false,
                         reactions: [],
                         isContinuation: continuation))
    }

    private func continued(_ rows: [TimelineRow]) -> [String] {
        var rows = rows
        TimelineMapper.markRunEnds(&rows)
        return rows.compactMap { $0.message?.isContinued == true ? $0.id : nil }
    }

    @Test("every message but the last of a run is continued")
    func lastOfRunIsNot() {
        let rows = [message("a"), message("b", continuation: true), message("c", continuation: true),
                    message("d"), message("e", continuation: true)]
        #expect(continued(rows) == ["a", "b", "d"])
    }

    /// A date or a grey line between two messages ends the run above it, whatever the senders.
    @Test("a divider ends the run above it")
    func dividerEndsRun() {
        let rows = [message("a"),
                    .dayDivider(DayDivider(id: "d", date: Date(timeIntervalSince1970: 0))),
                    message("b")]
        #expect(continued(rows).isEmpty)
    }

    /// Run again after more rows are appended — a message sent under our own last one moves the
    /// face down onto it — and run again with nothing appended changes nothing.
    @Test("marking again follows what was appended")
    func remarking() {
        var rows = [message("a"), message("b", continuation: true)]
        TimelineMapper.markRunEnds(&rows)
        rows.append(message("c", continuation: true))
        #expect(continued(rows) == ["a", "b"])
        rows.removeLast()
        #expect(continued(rows) == ["a"])
    }
}
