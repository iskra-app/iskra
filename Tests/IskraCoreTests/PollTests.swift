import Testing
import MatrixRustSDK
@testable import IskraCore

@Suite("Polls")
struct PollTests {
    private let answers = [PollAnswer(id: "a", text: "Вторник"),
                           PollAnswer(id: "b", text: "Среда"),
                           PollAnswer(id: "c", text: "Четверг")]

    private func poll(votes: [String: [String]], max: UInt64 = 1, kind: PollKind = .disclosed,
                      ended: Bool = false) -> Poll {
        Poll(question: "Когда?", kind: kind, maxSelections: max, answers: answers, votes: votes,
             isEnded: ended, ownUserID: "@me:x")
    }

    @Test("shares are of people, so a multiple-choice poll never adds up to more than everyone")
    func sharesArePerPerson() {
        let p = poll(votes: ["a": ["@1:x", "@2:x"], "b": ["@1:x", "@me:x"], "c": []], max: 3)
        #expect(p.voters == 3)
        #expect(p.share(of: p.answers[0]) == 2.0 / 3.0)
        #expect(p.answers[1].isChosen)
        #expect(!p.answers[0].isChosen)
    }

    @Test("votes for an answer the poll does not have are not counted")
    func unknownAnswersIgnored() {
        let p = poll(votes: ["z": ["@1:x"], "a": ["@2:x"]])
        #expect(p.voters == 1)
    }

    @Test("results show after your vote in an open poll, and only at the end in an anonymous one")
    func resultsVisibility() {
        #expect(!poll(votes: ["a": ["@1:x"]]).showsResults)
        #expect(poll(votes: ["a": ["@me:x"]]).showsResults)
        #expect(!poll(votes: ["a": ["@me:x"]], kind: .undisclosed).showsResults)
        #expect(poll(votes: [:], kind: .undisclosed, ended: true).showsResults)
    }

    @Test("winners are marked only once it is over, ties included")
    func winners() {
        #expect(!poll(votes: ["a": ["@1:x"]]).answers[0].isWinner)
        let over = poll(votes: ["a": ["@1:x"], "b": ["@2:x"]], ended: true)
        #expect(over.answers.map(\.isWinner) == [true, true, false])
        #expect(poll(votes: [:], ended: true).answers.allSatisfy { !$0.isWinner })
    }

    @Test("a tap swaps a single answer and toggles one of several, up to the limit")
    func tapping() {
        let single = poll(votes: ["a": ["@me:x"]])
        #expect(single.choice(afterTapping: "b") == ["b"])
        #expect(single.choice(afterTapping: "a") == nil)

        let two = poll(votes: ["a": ["@me:x"]], max: 2)
        #expect(two.choice(afterTapping: "b") == ["a", "b"])
        #expect(two.choice(afterTapping: "a") == [])

        let full = poll(votes: ["a": ["@me:x"], "b": ["@me:x"]], max: 2)
        #expect(full.choice(afterTapping: "c") == nil)

        #expect(poll(votes: [:], ended: true).choice(afterTapping: "a") == nil)
    }

    @Test("a draft needs a question and two answers, and blank ones do not count")
    func draft() {
        var d = PollDraft()
        d.question = "  "
        d.answers = ["Да", "Нет", ""]
        #expect(!d.canSend)
        d.question = "Идём?"
        #expect(d.canSend)
        d.answers = ["Да", "   ", ""]
        #expect(!d.canSend)
    }
}
