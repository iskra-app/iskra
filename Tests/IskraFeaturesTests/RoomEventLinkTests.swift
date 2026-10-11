import Foundation
import Testing
@testable import IskraCore
@testable import IskraFeatures

/// Names in the grey lines go to the people they name — Telegram's "Alice joined the group".
@Suite("Room event links")
struct RoomEventLinkTests {
    private func links(in text: AttributedString) -> [String: String] {
        var found: [String: String] = [:]
        for run in text.runs {
            guard let url = run.link, let id = RoomEventRow.userID(in: url) else { continue }
            found[String(text[run.range].characters)] = id
        }
        return found
    }

    @Test("each named person is a link to their Matrix ID")
    func namesAreLinks() {
        let event = RoomEvent(id: "1",
                              kind: .joined([RoomEventPerson(userID: "@anya:example.org", name: "Аня"),
                                             RoomEventPerson(userID: "@boris:example.org", name: "Борис")]),
                              timestamp: .now)
        let found = links(in: RoomEventRow.linked(event, linking: true))
        #expect(found["Аня"] == "@anya:example.org")
        #expect(found["Борис"] == "@boris:example.org")
    }

    @Test("a rename links the new name to whoever renamed themselves")
    func renameLinksActor() {
        let event = RoomEvent(id: "2", kind: .renamedThemselves(from: "Аня", to: "Анна"),
                              timestamp: .now, actorID: "@anya:example.org")
        #expect(links(in: RoomEventRow.linked(event, linking: true))["Анна"] == "@anya:example.org")
    }

    @Test("nowhere to go, nothing linked")
    func noRoomNoLinks() {
        let event = RoomEvent(id: "3", kind: .joined([RoomEventPerson(userID: "@a:b", name: "Аня")]), timestamp: .now)
        #expect(links(in: RoomEventRow.linked(event, linking: false)).isEmpty)
    }

    @Test("a Matrix ID survives the trip through a link")
    func roundTrip() throws {
        let id = "@weird+name/x:example.org"
        let url = try #require(RoomEventRow.link(to: id))
        #expect(RoomEventRow.userID(in: url) == id)
    }
}
