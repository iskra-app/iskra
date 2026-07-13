import Testing
@testable import IskraCore

/// A reaction that never left the send queue is still reported by the SDK as though it had.
/// These are the rules for taking it back off the screen.
@Suite("Unsent reactions")
struct UnsentReactionsTests {
    private let message = "$msg1"

    @Test("A reaction only we left disappears entirely")
    func ourOwnReactionIsRemoved() {
        var unsent = UnsentReactions()
        unsent.insert(messageID: message, key: "👍")

        let pills = unsent.applied(to: [MessageReaction(key: "👍", count: 1, isMine: true)],
                                   messageID: message)

        #expect(pills.isEmpty)
    }

    @Test("Other people's reactions stay, and stop being ours")
    func othersSurviveWithoutUs() {
        var unsent = UnsentReactions()
        unsent.insert(messageID: message, key: "👍")

        let pills = unsent.applied(to: [MessageReaction(key: "👍", count: 3, isMine: true)],
                                   messageID: message)

        // Two other people really did press it, and the pill is no longer lit as ours.
        #expect(pills == [MessageReaction(key: "👍", count: 2, isMine: false)])
    }

    @Test("Emoji we did not fail to send are untouched")
    func otherEmojiAreUntouched() {
        var unsent = UnsentReactions()
        unsent.insert(messageID: message, key: "👍")

        let pills = unsent.applied(to: [MessageReaction(key: "👍", count: 1, isMine: true),
                                        MessageReaction(key: "❤️", count: 1, isMine: true)],
                                   messageID: message)

        #expect(pills == [MessageReaction(key: "❤️", count: 1, isMine: true)])
    }

    /// The same emoji on a different message is a different reaction, and it may well have sent.
    @Test("Only the message it failed on is affected")
    func otherMessagesAreUntouched() {
        var unsent = UnsentReactions()
        unsent.insert(messageID: message, key: "👍")

        let pills = unsent.applied(to: [MessageReaction(key: "👍", count: 1, isMine: true)],
                                   messageID: "$msg2")

        #expect(pills == [MessageReaction(key: "👍", count: 1, isMine: true)])
    }

    /// A reaction of somebody else's that we never touched: `isMine` is false, so there is
    /// nothing of ours to subtract, and taking one off their count would invent a retraction.
    @Test("A pill that was never ours is not decremented")
    func aPillThatIsNotOursIsLeftAlone() {
        var unsent = UnsentReactions()
        unsent.insert(messageID: message, key: "👍")

        let pills = unsent.applied(to: [MessageReaction(key: "👍", count: 2, isMine: false)],
                                   messageID: message)

        #expect(pills == [MessageReaction(key: "👍", count: 2, isMine: false)])
    }

    @Test("Pressing it again brings the pill back")
    func retryingForgetsTheFailure() {
        var unsent = UnsentReactions()
        unsent.insert(messageID: message, key: "👍")
        unsent.remove(messageID: message, key: "👍")

        let reactions = [MessageReaction(key: "👍", count: 1, isMine: true)]
        #expect(unsent.applied(to: reactions, messageID: message) == reactions)
        #expect(unsent.isEmpty)
    }
}
