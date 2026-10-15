import Foundation
import Testing
@testable import IskraFeatures
import IskraCore

/// Several messages chosen at once — see `MessageSelection`.
@Suite("Message selection")
struct MessageSelectionTests {
    private func text(_ id: String, _ body: String, from name: String = "Аня") -> TimelineRow {
        .message(Message(id: id, kind: .text(body), senderID: "@\(id):example.org", senderName: name,
                         senderAvatarURL: nil, isOwn: false, timestamp: Date(timeIntervalSince1970: 0),
                         delivery: nil, isEdited: false, reactions: []))
    }

    @Test("what is done follows the conversation, not the order of the taps")
    func order() {
        let rows = [text("a", "раз"), text("b", "два"), text("c", "три")]
        var selection = MessageSelection("c")
        selection.toggle("a")
        #expect(selection.ordered(in: rows).map(\.id) == ["a", "c"])
        selection.toggle("c")
        #expect(selection.ordered(in: rows).map(\.id) == ["a"])
    }

    @Test("one message copies as its words, several as a transcript")
    func transcript() {
        let rows = [text("a", "раз"), text("b", "два", from: "Борис")]
        let one = MessageSelection("a").ordered(in: rows)
        #expect(MessageSelection.transcript(of: one) == "раз")

        var both = MessageSelection("a")
        both.toggle("b")
        let copied = MessageSelection.transcript(of: both.ordered(in: rows)) ?? ""
        #expect(copied.hasPrefix("Аня, ["))
        #expect(copied.contains("]\nраз\n\nБорис, ["))
        #expect(copied.hasSuffix("]\nдва"))
    }
}
