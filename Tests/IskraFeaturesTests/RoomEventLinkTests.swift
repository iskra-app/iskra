import Foundation
import Testing
@testable import IskraCore
@testable import IskraFeatures

/// Names in the grey lines go to the people they name — Telegram's "Alice joined the group".
@MainActor
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

    /// Display names are chosen by the people wearing them, so two can be made to match. Each link
    /// must land on its own word — the real Аня's name must never open the other Аня's page.
    @Test("two people with one name each keep their own link")
    func impostorCannotTakeTheName() {
        let event = RoomEvent(id: "4",
                              kind: .joined([RoomEventPerson(userID: "@real:example.org", name: "Аня"),
                                             RoomEventPerson(userID: "@fake:example.org", name: "Аня")]),
                              timestamp: .now)
        let text = RoomEventRow.linked(event, linking: true)
        let ids = text.runs.compactMap { run in run.link.flatMap(RoomEventRow.userID(in:)) }
        #expect(ids == ["@real:example.org", "@fake:example.org"])
    }

    @Test("a name inside another name does not take part of it")
    func nestedNames() {
        let event = RoomEvent(id: "5",
                              kind: .joined([RoomEventPerson(userID: "@bobby:example.org", name: "Бобби"),
                                             RoomEventPerson(userID: "@bob:example.org", name: "Боб")]),
                              timestamp: .now)
        let text = RoomEventRow.linked(event, linking: true)
        for run in text.runs {
            guard let id = run.link.flatMap(RoomEventRow.userID(in:)) else { continue }
            let word = String(text[run.range].characters)
            #expect((word == "Бобби" && id == "@bobby:example.org") || (word == "Боб" && id == "@bob:example.org"))
        }
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
