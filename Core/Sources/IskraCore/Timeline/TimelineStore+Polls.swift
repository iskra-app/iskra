import Foundation
import MatrixRustSDK

public extension TimelineStore {
    /// Answers a poll, or changes the answer. `answerIDs` is the whole new choice, not a delta:
    /// a poll response replaces the one before it, and an empty list takes the vote back.
    func vote(inPoll messageID: String, answerIDs: [String]) async {
        guard let timeline = liveTimeline, let eventID = eventID(for: messageID) else { return }
        do {
            try await timeline.sendPollResponse(pollStartEventId: eventID, answers: answerIDs)
        } catch {
            failure = .poll
        }
    }

    /// Closes a poll. Only its sender may, and the room counts nothing that arrives after.
    func endPoll(_ messageID: String) async {
        guard let timeline = liveTimeline, let eventID = eventID(for: messageID) else { return }
        do {
            try await timeline.endPoll(pollStartEventId: eventID,
                                       text: String(core: CoreStrings.Timeline.pollEndedBody))
        } catch {
            failure = .poll
        }
    }

    /// Sends a new poll. A disclosed poll shows the bars as soon as you have answered; an
    /// undisclosed one shows nothing until it is closed.
    func send(poll draft: PollDraft) async {
        guard let timeline = liveTimeline else {
            Log.media.error("nothing was sent: the room has no live timeline")
            failure = .send
            return
        }
        let answers = Array(draft.trimmedAnswers.prefix(PollDraft.maxAnswers))
        do {
            try await timeline.createPoll(question: draft.question.trimmingCharacters(in: .whitespacesAndNewlines),
                                          answers: answers,
                                          maxSelections: draft.isMultipleChoice ? UInt8(answers.count) : 1,
                                          pollKind: draft.isAnonymous ? .undisclosed : .disclosed)
        } catch {
            failure = .send
        }
    }
}
