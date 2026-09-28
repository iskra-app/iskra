import Testing
import UserNotifications
@testable import IskraFeatures

/// Two rules, and both of them are about *not* doing something twice: not opening a conversation
/// the reader has already left, and not announcing a message they are already watching arrive.
///
/// `PushRouter.shared` is a singleton because `UIApplication` speaks to one delegate and the
/// delegate needs somewhere to speak to. These tests use that same instance and put it back the way
/// they found it — there is nothing here worth a second initialiser.
@MainActor
struct PushRouterTests {
    private func fresh() -> PushRouter {
        let router = PushRouter.shared
        _ = router.takeRoomToOpen()
        router.visibleRoomID = nil
        router.visibleAccountID = nil
        return router
    }

    @Test("a tapped notification names the room to open")
    func tapNamesTheRoom() {
        let router = fresh()
        router.tapped(roomID: "!kitchen:matrix.org")

        #expect(router.roomToOpen == "!kitchen:matrix.org")
        #expect(router.takeRoomToOpen() == "!kitchen:matrix.org")
    }

    @Test("the room is taken once, not read forever")
    func theRoomIsTakenOnce() {
        let router = fresh()
        router.tapped(roomID: "!kitchen:matrix.org")
        _ = router.takeRoomToOpen()

        // The second foreground is somebody coming back to the app on their own business. Handing
        // them the same room again would drag them back to a conversation they have since left.
        #expect(router.takeRoomToOpen() == nil)
        #expect(router.roomToOpen == nil)
    }

    @Test("a push about another conversation is still worth a banner")
    func anotherConversationIsNews() {
        let router = fresh()
        router.visibleRoomID = "!kitchen:matrix.org"

        let options = router.presentation(forRoomID: "!garden:matrix.org")
        #expect(options.contains(.banner))
        #expect(options.contains(.sound))
    }

    @Test("the conversation on screen does not announce itself")
    func theVisibleRoomIsSilent() {
        let router = fresh()
        router.visibleRoomID = "!kitchen:matrix.org"

        // The message is arriving in the timeline behind the banner. Showing it would be the same
        // sentence twice, and sounding it would be a second alert for one event.
        #expect(router.presentation(forRoomID: "!kitchen:matrix.org").isEmpty)
    }

    @Test("with nothing on screen, everything is news")
    func nothingOnScreenMeansEverythingShows() {
        let router = fresh()

        // The chat list, or the app in a pocket. Nothing is being watched, so nothing is a repeat.
        #expect(router.presentation(forRoomID: "!kitchen:matrix.org").contains(.banner))
        // And a push the extension could not attribute to a room is shown rather than swallowed:
        // an unexplained notification is a smaller failure than a missing one.
        #expect(router.presentation(forRoomID: nil).contains(.banner))
    }

    // MARK: - More than one account

    @Test("a tap says whose room it is, and both are taken together")
    func tapCarriesTheAccount() throws {
        let router = fresh()
        router.tapped(roomID: "!kitchen:matrix.org", accountID: "two")

        let request = try #require(router.takeRequest())
        #expect(request.roomID == "!kitchen:matrix.org")
        #expect(request.accountID == "two")
        #expect(router.takeRequest() == nil)
    }

    /// Two people on one phone can share a room. A message there for the account that is *not* on
    /// screen is news to that account, however open the same room is in the other one.
    @Test("the same room in another account still gets its banner")
    func anotherAccountsCopyOfTheRoomIsNews() {
        let router = fresh()
        router.visibleRoomID = "!kitchen:matrix.org"
        router.visibleAccountID = "one"

        #expect(router.presentation(forRoomID: "!kitchen:matrix.org", accountID: "two").contains(.banner))
        #expect(router.presentation(forRoomID: "!kitchen:matrix.org", accountID: "one").isEmpty)
    }
}
