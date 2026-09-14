import Testing
import SwiftUI
@testable import IskraDesign
@testable import IskraFeatures

/// Where the message menu puts itself — see `MessageMenuLayout`.
///
/// The arithmetic is in a type of its own precisely so it can be checked here, because every
/// one of these cases is otherwise found by a person holding a phone: a message at the very
/// bottom of the screen with a menu hanging off the end of it, a photograph so tall the verbs
/// are pushed past the home indicator, a reply on the right-hand side whose menu opens off the
/// left edge. None of them fail loudly. They just look wrong, on one screen size, once.
@MainActor
struct MessageMenuLayoutTests {
    /// A phone, and the part of it the menu may use: the window less the island at the top and
    /// the home indicator at the foot. The menu is handed this rectangle in the same coordinates
    /// the messages are measured in, so a region that starts at y = 59 is the whole of what it
    /// knows about the Dynamic Island — and the one thing it must never draw under.
    private let region = CGRect(x: 0, y: 59, width: 393, height: 852 - 59 - 34)

    /// Five verbs.
    private let list = Theme.Size.menuRow * 5
    private let bar = Theme.Size.reactionBar

    private func resolve(anchor: CGRect,
                         isOwn: Bool = false,
                         region: CGRect? = nil,
                         listHeight: CGFloat? = nil) -> MessageMenuLayout {
        MessageMenuLayout.resolve(anchor: anchor,
                                  region: region ?? self.region,
                                  isOwn: isOwn,
                                  aboveHeight: bar,
                                  listHeight: listHeight ?? list)
    }

    /// Everything below is in the region's own coordinates, which is what `resolve` answers in.
    private func local(_ anchor: CGRect, in region: CGRect? = nil) -> CGRect {
        let region = region ?? self.region
        return anchor.offsetBy(dx: -region.minX, dy: -region.minY)
    }

    /// The whole point of the lift: a message in the middle of the screen does not move. The bar
    /// of emoji opens in the space above it and the verbs below, and the thing being talked
    /// about stays exactly where the finger left it.
    @Test func aMessageInTheMiddleStaysWhereItIs() {
        let anchor = CGRect(x: 16, y: 400, width: 220, height: 60)
        let layout = resolve(anchor: anchor)

        #expect(layout.origin.y == local(anchor).minY - bar - MessageMenu.gap)
        #expect(layout.contentScale == 1)
        #expect(layout.listMaxHeight == list)
    }

    /// A message down by the composer has no room under it, so the whole arrangement comes up
    /// far enough for the last verb to clear the home indicator — and no further.
    @Test func aMessageAtTheBottomIsLiftedJustEnough() {
        let layout = resolve(anchor: CGRect(x: 16, y: 780, width: 220, height: 50))

        let columnHeight = bar + MessageMenu.gap + 50 + MessageMenu.gap + list
        #expect(layout.origin.y == region.height - MessageMenu.margin - columnHeight)
        #expect(layout.origin.y + columnHeight <= region.height)
    }

    /// A message at the top of the conversation opens its bar of emoji *below* the island, not
    /// under it.
    ///
    /// This is the one in the file that was found by a person rather than by a test, and it was
    /// found because the bar was drawn under the clock and the battery where it could be seen
    /// and not pressed. The cause was a safe area reported as zero by a reader that had been
    /// told to ignore it — so what is checked here is the arithmetic, and what fixed the app was
    /// handing that arithmetic a region somebody had actually measured. See `MessageMenuOverlay`.
    @Test func aMessageAtTheTopOpensBelowTheIsland() {
        let layout = resolve(anchor: CGRect(x: 16, y: 70, width: 220, height: 50))

        #expect(layout.origin.y == MessageMenu.margin)
        #expect(layout.origin.y + region.minY >= region.minY + MessageMenu.margin)
    }

    /// And one the conversation has scrolled up *behind* the island — an anchor whose top is
    /// above the region entirely — is treated the same way rather than followed off the screen.
    @Test func aMessageBehindTheIslandDoesNotDragTheMenuUpWithIt() {
        let layout = resolve(anchor: CGRect(x: 16, y: 20, width: 220, height: 50))

        #expect(layout.origin.y == MessageMenu.margin)
    }

    /// Your own message hangs from the right-hand edge, so the menu opens from the right-hand
    /// edge. Anything else reads as a menu belonging to the screen rather than to the message.
    @Test func yourOwnMessageOpensUnderItsTrailingEdge() {
        let anchor = CGRect(x: 150, y: 300, width: 200, height: 44)
        let layout = resolve(anchor: anchor, isOwn: true)

        #expect(layout.origin.x + layout.width == local(anchor).maxX)
    }

    /// Somebody else's opens under its leading edge — unless the list is wider than the room
    /// left to the right of it, in which case it is the margin that wins.
    @Test func aMenuNeverHangsOffTheEdgeOfTheScreen() {
        let layout = resolve(anchor: CGRect(x: 300, y: 300, width: 80, height: 44))

        #expect(layout.origin.x >= MessageMenu.margin)
        #expect(layout.origin.x + layout.width <= region.width - MessageMenu.margin)
    }

    /// A very long message is what shrinks, and it shrinks *first*: the bar and the verbs are a
    /// fixed cost, and a photograph that pushed them off the screen would leave a menu with no
    /// menu in it.
    @Test func aTallMessageGivesWayBeforeTheMenuDoes() {
        let layout = resolve(anchor: CGRect(x: 16, y: 100, width: 260, height: 700))

        #expect(layout.contentScale < 1)
        #expect(layout.listMaxHeight == list)

        let columnHeight = bar + MessageMenu.gap + 700 * layout.contentScale + MessageMenu.gap + list
        #expect(layout.origin.y + columnHeight <= region.height - MessageMenu.margin + 0.001)
    }

    /// But only so far. Past a couple of lines the lifted message stops being the message and
    /// starts being a smudge, so it stops giving and the list begins to scroll instead.
    @Test func aShortScreenScrollsTheListRatherThanCrushingTheMessage() {
        let short = CGRect(x: 0, y: 59, width: 393, height: 420)
        let layout = resolve(anchor: CGRect(x: 16, y: 100, width: 260, height: 600),
                             region: short,
                             listHeight: Theme.Size.menuRow * 9)

        let contentHeight = 600 * layout.contentScale
        #expect(contentHeight >= MessageMenuLayout.leastContentHeight - 0.001)
        #expect(layout.listMaxHeight < Theme.Size.menuRow * 9)
        #expect(layout.listMaxHeight >= Theme.Size.menuRow)
    }

    /// On a narrow window the list is the window's width less its margins, not its own idea of
    /// how wide a menu should be.
    @Test func aNarrowWindowNarrowsTheMenu() {
        let narrow = CGRect(x: 0, y: 0, width: 240, height: 600)
        let layout = resolve(anchor: CGRect(x: 16, y: 200, width: 180, height: 44), region: narrow)

        #expect(layout.width == narrow.width - MessageMenu.margin * 2)
    }

    /// A wide message — a picture on an iPad — does *not* widen the menu. The menu is one
    /// width everywhere, so the verbs are in the same place on every message; the picture is
    /// still lifted at its own size, which is the part that has to be true of the message and
    /// not of the list under it.
    @Test func aWideMessageLeavesTheMenuAlone() {
        let pad = CGRect(x: 0, y: 24, width: 1024, height: 1366)
        let layout = resolve(anchor: CGRect(x: 40, y: 400, width: 420, height: 300), region: pad)

        #expect(layout.width == Theme.Size.menuWidth)
    }

    /// And a short one does not narrow it either — the two ends of the same rule.
    @Test func aShortMessageLeavesTheMenuAlone() {
        let layout = resolve(anchor: CGRect(x: 16, y: 400, width: 48, height: 36))

        #expect(layout.width == Theme.Size.menuWidth)
    }

    // MARK: - The grid of every emoji, which is wider than the rest

    /// The panel behind the "+" is a grid and not a column of words, so it is half again as
    /// wide as the menu — and it still hangs from the edge the message hangs from. See
    /// `Theme.Size.emojiPanelWidth`.
    @Test func theEmojiPanelIsWiderThanTheMenuAndHangsFromTheSameEdge() {
        let anchor = CGRect(x: 16, y: 300, width: 200, height: 44)
        let layout = resolve(anchor: anchor)

        #expect(layout.emojiWidth == Theme.Size.emojiPanelWidth)
        #expect(layout.emojiWidth > layout.width)
        // Nothing to correct: the message is nowhere near an edge.
        #expect(layout.emojiOffset == 0)
    }

    /// And on your own message, which hangs from the right, it grows to the left.
    @Test func theEmojiPanelOnYourOwnMessageGrowsInwards() {
        let anchor = CGRect(x: 150, y: 300, width: 200, height: 44)
        let layout = resolve(anchor: anchor, isOwn: true)

        // Its trailing edge is the menu's trailing edge, and it is still on the screen.
        #expect(layout.origin.x + layout.width - layout.emojiWidth + layout.emojiOffset >= MessageMenu.margin)
    }

    /// The case the extra width invents, and the reason the offset exists at all: a message on
    /// the left of a narrow screen, whose panel would otherwise grow straight off the right.
    ///
    /// Without the correction this is a grid of emoji with its last two columns past the edge of
    /// the phone — the sort of thing that is obvious on one screen size and invisible on the one
    /// it was built on.
    @Test func theEmojiPanelIsSlidBackOntoTheScreen() {
        let narrow = CGRect(x: 0, y: 59, width: 320, height: 700)
        let layout = resolve(anchor: CGRect(x: 60, y: 300, width: 200, height: 44), region: narrow)

        let leading = layout.origin.x + layout.emojiOffset
        #expect(leading >= MessageMenu.margin)
        #expect(leading + layout.emojiWidth <= narrow.width - MessageMenu.margin)
    }

    /// On a screen narrower than the panel wants to be, it is simply as wide as there is room
    /// for. A panel that insisted on 360 points would be a grid nobody could reach the last
    /// column of.
    @Test func theEmojiPanelNeverOutgrowsTheScreen() {
        let narrow = CGRect(x: 0, y: 59, width: 320, height: 700)
        let layout = resolve(anchor: CGRect(x: 16, y: 300, width: 200, height: 44), region: narrow)

        #expect(layout.emojiWidth == narrow.width - MessageMenu.margin * 2)
    }
}

/// The short list of emoji behind the "+" — see `RecentEmoji`.
struct RecentEmojiTests {
    @Test func theLatestComesFirst() {
        let stored = RecentEmoji.adding("🎉", to: RecentEmoji.adding("👍", to: ""))
        #expect(RecentEmoji.list(from: stored) == ["🎉", "👍"])
    }

    /// Sending the same emoji again moves it to the front rather than putting it in twice —
    /// otherwise a person with one favourite would have a "recent" list of nothing else.
    @Test func sendingOneAgainMovesItRatherThanRepeatingIt() {
        var stored = ""
        for emoji in ["👍", "🎉", "👍"] { stored = RecentEmoji.adding(emoji, to: stored) }

        #expect(RecentEmoji.list(from: stored) == ["👍", "🎉"])
    }

    @Test func theListStopsAtItsLimit() {
        var stored = ""
        for index in 0..<(RecentEmoji.limit + 10) {
            stored = RecentEmoji.adding(String(UnicodeScalar(0x1F600 + index)!), to: stored)
        }

        #expect(RecentEmoji.list(from: stored).count == RecentEmoji.limit)
    }
}
