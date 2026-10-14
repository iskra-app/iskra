import Testing
import Foundation
@testable import IskraCore

/// The last line of a chat's row, chosen from the chat's own rows — see `PeekLine`.
struct PeekLineTests {
    private func message(_ kind: MessageKind, isOwn: Bool = false, delivery: DeliveryStatus? = nil,
                         at seconds: TimeInterval = 0) -> TimelineRow {
        .message(Message(id: "$\(seconds)",
                         kind: kind,
                         senderID: isOwn ? "@me:example.org" : "@a:example.org",
                         senderName: "А",
                         senderAvatarURL: nil,
                         isOwn: isOwn,
                         timestamp: Date(timeIntervalSince1970: seconds),
                         delivery: delivery,
                         isEdited: false,
                         reactions: []))
    }

    @Test("a deleted message is the last line, not the one before it")
    func deletedIsShown() {
        let line = PeekLine.last(in: [message(.text("hi"), at: 1), message(.deleted, at: 2)])
        #expect(line?.text == MessagePreview.text(for: .deleted))
        #expect(line?.date == Date(timeIntervalSince1970: 2))
    }

    @Test("a grey line is the last line")
    func roomEventIsShown() {
        let event = RoomEvent(id: "$j", kind: .joined(["Аня"]), timestamp: Date(timeIntervalSince1970: 3))
        let line = PeekLine.last(in: [message(.text("hi"), at: 1), .event(event), .unreadDivider])
        #expect(line?.text == event.text)
        #expect(line?.mark == nil)
    }

    @Test("your own message read on the other side says so")
    func readMark() {
        let line = PeekLine.last(in: [message(.text("hi"), isOwn: true, delivery: .read)])
        #expect(line?.mark == .read)
    }

    @Test("your own deleted message wears no mark")
    func deletedHasNoMark() {
        let line = PeekLine.last(in: [message(.deleted, isOwn: true, delivery: .read)])
        #expect(line?.mark == nil)
    }

    @Test("something the chat has no words for leaves the row to the SDK")
    func unsupportedFallsBack() {
        #expect(PeekLine.last(in: [message(.text("hi")), message(.unsupported, at: 1)]) == nil)
        #expect(PeekLine.last(in: []) == nil)
    }

    @Test("an attachment keeps its icon")
    func attachmentKind() {
        #expect(PeekLine.last(in: [message(.file(.picture(url: "mxc://a/b")!))])?.kind == .file)
    }
}
