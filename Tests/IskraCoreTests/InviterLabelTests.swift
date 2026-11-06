import Testing
@testable import IskraCore

/// Who is named in the question before joining a room. A display name is whatever its owner typed.
@Suite("Inviter label")
struct InviterLabelTests {
    private func label(name: String?, id: String?) -> String? {
        RoomSummary(id: "!r:x", name: "Room", membership: .invited, invitedBy: name, invitedByID: id).inviterLabel
    }

    private let id = "@eve:evil.example"
    private let open = "\u{2068}", close = "\u{2069}"

    @Test("the ID comes first and the name is isolated")
    func idFirst() {
        #expect(label(name: "Ева", id: id) == "\(id) (\(open)Ева\(close))")
    }

    @Test("nobody known, nobody named")
    func unknown() {
        #expect(label(name: "Ева", id: nil) == nil)
    }

    @Test("a name that is only the ID is not said twice")
    func sameAsID() {
        #expect(label(name: id, id: id) == id)
    }

    @Test("another ID written into a name is taken out")
    func nameCannotPoseAsAnID() {
        #expect(label(name: "Мама @mama:matrix.org", id: id) == "\(id) (\(open)Мама\(close))")
    }

    @Test("line breaks and direction marks are taken out of a name")
    func nameCannotReorderText() {
        #expect(label(name: "Ма\nма\u{202E}\u{200B}", id: id) == "\(id) (\(open)Мама\(close))")
    }

    @Test("a long name is cut")
    func longName() throws {
        let text = try #require(label(name: String(repeating: "я", count: 200), id: id))
        #expect(text.count == id.count + " ()".count + 2 + 64)
    }

    @Test("an ID that is not plain ASCII is not shown, and is never tidied into somebody else's")
    func oddIDIsUnknown() {
        #expect(label(name: "Ева", id: "@eve\u{200B}:evil.example") == nil)
        #expect(label(name: "Ева", id: "@е\u{0432}e:evil.example") == nil)
        #expect(label(name: "Ева", id: "eve") == nil)
    }

    @Test("an ID in lookalike characters is taken out of a name too")
    func lookalikeIDInName() {
        #expect(label(name: "Мама ＠mama：matrix.org", id: id) == "\(id) (\(open)Мама\(close))")
        #expect(label(name: "Мама @mama∶matrix.org", id: id) == "\(id) (\(open)Мама\(close))")
    }

    @Test("marks stuck to the @ or the colon do not hide an ID in a name")
    func marksInIDInName() {
        for mark in ["\u{FE00}", "\u{034F}", "\u{0301}"] {
            #expect(label(name: "Мама @\(mark)mama:\(mark)matrix.org", id: id) == "\(id) (\(open)Мама\(close))")
        }
    }
}
