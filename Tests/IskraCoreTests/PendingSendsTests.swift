import Foundation
import Testing
@testable import IskraCore

/// A message put on the screen the instant it is sent, and taken off again when the SDK's own
/// echo of it arrives. There is nothing but the words to match the two by — see `PendingSends` —
/// so these are the rules for that guess, and for which way it is allowed to be wrong.
@Suite("Pending sends")
struct PendingSendsTests {
    private let me = "@me:iskra.chat"

    private func mine(_ text: String, at date: Date) -> TimelineRow {
        .message(Message(id: "$\(text)-\(date.timeIntervalSince1970)",
                         kind: .text(text),
                         senderID: me,
                         senderName: "Я",
                         senderAvatarURL: nil,
                         isOwn: true,
                         timestamp: date,
                         delivery: .sent,
                         isEdited: false,
                         reactions: []))
    }

    private func theirs(_ text: String, at date: Date) -> TimelineRow {
        .message(Message(id: "$them-\(text)",
                         kind: .text(text),
                         senderID: "@them:iskra.chat",
                         senderName: "Они",
                         senderAvatarURL: nil,
                         isOwn: false,
                         timestamp: date,
                         delivery: nil,
                         isEdited: false,
                         reactions: []))
    }

    @Test("A message with no echo yet stays on the screen")
    func waitsForItsEcho() {
        var pending = PendingSends()
        pending.add(text: "привет", replyingTo: nil)

        pending.pruneEchoed(in: [mine("что-то ещё", at: .now)])

        #expect(pending.all.count == 1)
        #expect(pending.all.first?.text == "привет")
    }

    @Test("The echo takes its place")
    func echoRetiresIt() {
        var pending = PendingSends()
        pending.add(text: "привет", replyingTo: nil)

        pending.pruneEchoed(in: [mine("привет", at: .now)])

        #expect(pending.isEmpty)
    }

    @Test("The same words from somebody else are not our echo")
    func theirMessageIsNotOurEcho() {
        var pending = PendingSends()
        pending.add(text: "привет", replyingTo: nil)

        pending.pruneEchoed(in: [theirs("привет", at: .now)])

        #expect(pending.all.count == 1)
    }

    @Test("Two of the same are retired one echo at a time")
    func echoesAreCounted() {
        var pending = PendingSends()
        pending.add(text: "ок", replyingTo: nil)
        pending.add(text: "ок", replyingTo: nil)

        pending.pruneEchoed(in: [mine("ок", at: .now)])

        #expect(pending.all.count == 1)

        pending.pruneEchoed(in: [mine("ок", at: .now), mine("ок", at: .now)])

        #expect(pending.isEmpty)
    }

    /// The oldest one goes first. Both stand-ins say the same thing, so which of them is retired
    /// changes nothing on screen — but the one left behind is the one still waiting, and it is the
    /// *newest* send that is still waiting.
    @Test("The oldest of two identical messages is the one retired")
    func theOldestGoesFirst() {
        var pending = PendingSends()
        let first = pending.add(text: "ок", replyingTo: nil, at: .now - 10)
        let second = pending.add(text: "ок", replyingTo: nil, at: .now)

        pending.pruneEchoed(in: [mine("ок", at: .now)])

        #expect(pending.all.map(\.id) == [second])
        #expect(!pending.all.map(\.id).contains(first))
    }

    /// A message from an hour ago cannot be the echo of something sent a second ago, and treating
    /// it as one would take the stand-in away and leave nothing in its place.
    @Test("An old message of ours is not mistaken for the echo")
    func farOlderMessagesAreIgnored() {
        var pending = PendingSends()
        pending.add(text: "привет", replyingTo: nil)

        pending.pruneEchoed(in: [mine("привет", at: .now - 3600)])

        #expect(pending.all.count == 1)
    }

    /// The bias, written down as a test: an echo timestamped a little *before* the press — clock
    /// skew, a queue that had been paused — still counts. Retiring a stand-in too eagerly costs
    /// the few hundred milliseconds this exists to save; retiring one too late puts the same
    /// sentence in the conversation twice.
    @Test("An echo timestamped just before the press still counts")
    func slightlyEarlierEchoesCount() {
        var pending = PendingSends()
        pending.add(text: "привет", replyingTo: nil)

        pending.pruneEchoed(in: [mine("привет", at: .now - 5)])

        #expect(pending.isEmpty)
    }

    @Test("A message the SDK refused is taken back by hand")
    func removeByID() {
        var pending = PendingSends()
        let id = pending.add(text: "привет", replyingTo: nil)
        pending.add(text: "пока", replyingTo: nil)

        pending.remove(id: id)

        #expect(pending.all.map(\.text) == ["пока"])
    }

    @Test("Putting the room down forgets everything on its way out")
    func removeAll() {
        var pending = PendingSends()
        pending.add(text: "привет", replyingTo: nil)
        pending.removeAll()

        #expect(pending.isEmpty)
    }

    /// Photographs, voice notes and the rest go out through `TimelineStore+Media` and are echoed
    /// by the SDK on their own; nothing here should be retired by one that happens to carry the
    /// same caption.
    @Test("Only our own text messages can be an echo")
    func onlyTextCounts() {
        var pending = PendingSends()
        pending.add(text: "привет", replyingTo: nil)

        let notice = TimelineRow.message(Message(id: "$notice",
                                                 kind: .notice("привет"),
                                                 senderID: me,
                                                 senderName: "Я",
                                                 senderAvatarURL: nil,
                                                 isOwn: true,
                                                 timestamp: .now,
                                                 delivery: .sent,
                                                 isEdited: false,
                                                 reactions: []))

        pending.pruneEchoed(in: [notice])

        #expect(pending.all.count == 1)
    }
}
