import Testing
@testable import IskraFeatures

/// The rule that decides which messages are seen to arrive.
///
/// It is pure — a list of row identities and the one that used to be last — and it is tested
/// because it has been wrong three times, each time in a way that only showed up as somebody
/// watching a screen and saying the conversation looked wrong. See `MessageArrivals`.
@Suite struct MessageArrivalsTests {
    @Test func aMessageSaidAfterTheLastOneArrives() {
        let index = MessageArrivals.firstArriving(in: ["a", "b", "c"], after: "b")
        #expect(index == 2)
    }

    @Test func severalAtOnceAllArrive() {
        let index = MessageArrivals.firstArriving(in: ["a", "b", "c", "d"], after: "b")
        #expect(index == 2)
    }

    /// The one that matters most: a page of history is twenty-five rows the reader did not ask
    /// to watch appear. It lands *above* what is already there, so the end has not moved.
    @Test func aPageOfHistoryArrivesNowhere() {
        let ids = ["old1", "old2", "old3", "a", "b"]
        let index = MessageArrivals.firstArriving(in: ids, after: "b")
        #expect(index == ids.count)
    }

    /// A message of ours goes on the screen before the server has echoed it, and is replaced by
    /// the real one a few hundred milliseconds later. The replacement is not a second arrival —
    /// the same words must not be seen to land twice.
    @Test func anEchoTakingOverFromOurOwnBubbleIsNotAnArrival() {
        let ids = ["a", "b", "$event"]
        let index = MessageArrivals.firstArriving(in: ids, after: "pending-1")
        #expect(index == ids.count)
    }

    /// Opening a room: nothing was there before, so nothing is arriving. Fifteen bubbles
    /// springing in together is not an arrival, it is the whole room twitching.
    @Test func theFirstRowsOfARoomDoNotArrive() {
        let ids = ["a", "b", "c"]
        #expect(MessageArrivals.firstArriving(in: ids, after: nil) == ids.count)
    }

    @Test func nothingChangingMeansNothingArriving() {
        let ids = ["a", "b", "c"]
        #expect(MessageArrivals.firstArriving(in: ids, after: "c") == ids.count)
    }

    @Test func anEmptyRoomHasNothingToAnimate() {
        #expect(MessageArrivals.firstArriving(in: [], after: "a") == 0)
    }
}
