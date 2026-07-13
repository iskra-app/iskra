import Foundation
import Testing
@testable import IskraCore

/// The grey lines across a conversation: who is on them, and whether they pool.
@Suite("Room events")
struct RoomEventTests {
    /// Two people joining one after the other is one line, not two. This is the whole reason
    /// `RoomEventKind` is a structure and not a finished sentence.
    @Test("consecutive joins pool into one line")
    func joinsPool() {
        let pooled = RoomEventKind.joined(["Аня"]).merged(with: .joined(["Борис"]))
        #expect(pooled == .joined(["Аня", "Борис"]))
    }

    /// And two *different* things do not. "Аня вошла" and "Борис вышел" pooled into one line
    /// would be a sentence that is untrue of both of them.
    @Test("a join and a departure stay two lines")
    func differentEventsDoNotPool() {
        #expect(RoomEventKind.joined(["Аня"]).merged(with: .left(["Борис"])) == nil)
        #expect(RoomEventKind.roomCreated.merged(with: .roomCreated) == nil)
    }

    /// Somebody who leaves and comes back in the same minute is one person, not two.
    @Test("the same person is not counted twice")
    func namesAreNotDuplicated() {
        let pooled = RoomEventKind.joined(["Аня"]).merged(with: .joined(["Аня", "Борис"]))
        #expect(pooled == .joined(["Аня", "Борис"]))
    }

    /// Russian declines the people after the number — 1 участник, 2 участника, 5 участников —
    /// and this line is where a room with a busy morning ends up. It goes through
    /// `Localizable.stringsdict`, which is new to `IskraCore`: the module had only a `.strings`
    /// until room events needed a plural, so this test is also the proof that the file is in
    /// the bundle at all.
    @Test("the pooled count declines in Russian")
    func pooledCountDeclines() {
        func others(_ count: Int, _ language: String) -> String {
            var resource = CoreStrings.RoomEvent.others("Аня", count)
            resource.locale = Locale(identifier: language)
            return String(localized: resource)
        }

        #expect(others(1, "ru") == "Аня и ещё 1 участник")
        #expect(others(2, "ru") == "Аня и ещё 2 участника")
        #expect(others(5, "ru") == "Аня и ещё 5 участников")

        #expect(others(1, "en") == "Аня and 1 other")
        #expect(others(5, "en") == "Аня and 5 others")
    }

    /// One person is a name; two are both named; three or more become a name and a count. A
    /// grey line listing eleven people is not a line, it is a paragraph.
    @Test("people are named up to two and counted after that")
    func peopleAreListed() {
        func line(_ names: [String]) -> String {
            RoomEvent(id: "1", kind: .joined(names), timestamp: .now).text
        }

        #expect(line(["Аня"]).contains("Аня"))
        #expect(line(["Аня", "Борис"]).contains("Борис"))
        // Three people: the first by name, the other two as a number — never all three.
        #expect(line(["Аня", "Борис", "Витя"]).contains("Аня"))
        #expect(!line(["Аня", "Борис", "Витя"]).contains("Витя"))
    }
}
