import Foundation
import MatrixRustSDK

/// A poll, as the room has counted it so far.
///
/// The SDK does the counting — it gathers every `m.poll.response` under its `m.poll.start`, keeps
/// only each person's latest answer, ignores what came in after the end — and hands back who chose
/// what. This is that tally turned round into what a bubble draws: per answer, how many and whether
/// one of them is you.
///
/// Votes are counted by *person*, not by answer. In a poll where you may pick two, three people
/// can cast five votes, and "60%" has to mean "three of five people", not "three of five ticks" —
/// otherwise the bars of a multiple-choice poll add up to more than the whole.
public struct Poll: Sendable, Equatable {
    public struct Answer: Sendable, Equatable, Identifiable {
        public let id: String
        public let text: String
        public let votes: Int
        /// One of the votes is this account's.
        public let isChosen: Bool
        /// The most votes of any answer, once the poll is over. Several can share it.
        public let isWinner: Bool
    }

    public let question: String
    public let answers: [Answer]

    /// How many answers one person may pick. One is the ordinary poll.
    public let maxSelections: Int

    /// Whether anybody may see how it is going before it ends. An undisclosed poll shows nothing
    /// but the question until it is closed — that is what its sender asked for, and a client that
    /// showed the bars anyway would be overruling them.
    public let isDisclosed: Bool

    public let isEnded: Bool

    /// How many different people have answered.
    public let voters: Int

    public init(question: String,
                answers: [Answer],
                maxSelections: Int,
                isDisclosed: Bool,
                isEnded: Bool,
                voters: Int) {
        self.question = question
        self.answers = answers
        self.maxSelections = max(1, maxSelections)
        self.isDisclosed = isDisclosed
        self.isEnded = isEnded
        self.voters = voters
    }

    /// Builds one out of the SDK's tally. `votes` is answer ID → the people who chose it.
    init(question: String,
         kind: PollKind,
         maxSelections: UInt64,
         answers: [PollAnswer],
         votes: [String: [String]],
         isEnded: Bool,
         ownUserID: String) {
        let known = Set(answers.map(\.id))
        let counted = votes.filter { known.contains($0.key) }
        let voters = Set(counted.values.flatMap { $0 }).count
        let most = isEnded ? (counted.values.map(\.count).max() ?? 0) : 0

        self.init(question: question,
                  answers: answers.map { answer in
                      let people = counted[answer.id] ?? []
                      return Answer(id: answer.id,
                                    text: answer.text,
                                    votes: people.count,
                                    isChosen: people.contains(ownUserID),
                                    isWinner: most > 0 && people.count == most)
                  },
                  maxSelections: Int(clamping: maxSelections),
                  isDisclosed: kind == .disclosed,
                  isEnded: isEnded,
                  voters: voters)
    }

    public var isMultipleChoice: Bool { maxSelections > 1 }

    public var hasVoted: Bool { answers.contains(where: \.isChosen) }

    /// The bars are drawn once the poll is over, or — in an open poll — once you have answered it.
    /// Before that they would only steer the answer.
    public var showsResults: Bool {
        isEnded || (isDisclosed && hasVoted)
    }

    /// The share of the people who voted that chose this answer, 0…1.
    public func share(of answer: Answer) -> Double {
        voters == 0 ? 0 : Double(answer.votes) / Double(voters)
    }

    /// What this account's choice becomes after a tap on `answerID`.
    ///
    /// A single-choice poll swaps the answer. A multiple-choice one toggles it, and refuses to go
    /// past `maxSelections` rather than dropping some earlier tick behind the user's back. Nil
    /// means the tap changes nothing.
    public func choice(afterTapping answerID: String) -> [String]? {
        guard !isEnded, answers.contains(where: { $0.id == answerID }) else { return nil }
        let chosen = answers.filter(\.isChosen).map(\.id)

        guard isMultipleChoice else {
            return chosen == [answerID] ? nil : [answerID]
        }
        if chosen.contains(answerID) {
            return chosen.filter { $0 != answerID }
        }
        guard chosen.count < maxSelections else { return nil }
        return chosen + [answerID]
    }
}

/// A poll somebody is about to send.
public struct PollDraft: Sendable, Equatable {
    public var question = ""
    public var answers = ["", ""]
    public var isMultipleChoice = false
    /// Results hidden until the poll ends.
    public var isAnonymous = false

    public init() {}

    /// Matrix allows twenty, and a poll with more is a form, not a question.
    public static let maxAnswers = 20

    public var trimmedAnswers: [String] {
        answers.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    public var canSend: Bool {
        !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && trimmedAnswers.count >= 2
    }
}
