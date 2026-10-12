import SwiftUI
import IskraCore
import IskraDesign

/// The menu a long press on a message opens — ours, drawn by us, rather than the system's.
///
/// This is the second time this app has drawn its own message menu, and the first attempt is
/// worth knowing about because the reasons it was thrown away are the things this one has to
/// get right. It was a quarter-second press opening a *popover*: no lift, no dim, none of the
/// system's animation, and a menu that looked like a menu from a different app. Going back to
/// `.contextMenu` bought all of that back for nothing.
///
/// What `.contextMenu` cannot do is the two things this menu exists for:
///
/// - **A menu with nothing in it that we did not put there.** On iOS 27 the system adds its own
///   items to a context menu — "Ask Siri" among them — and there is no API to decline. A
///   message in an end-to-end encrypted conversation is the last place in this app that should
///   grow a button offering to send its contents somewhere else.
/// - **Any emoji, not six.** A `ControlGroup` of six buttons is the whole of what a system menu
///   will show side by side. The "+" here opens the rest — see `EmojiCatalog`.
///
/// So the menu is ours again, and this time it is the system's *shape*: the conversation
/// darkens and goes soft behind it, the message itself lifts off the page and stays legible
/// while you choose, the bar of emoji and the column of verbs arrive on a spring around it.
/// Liquid Glass on both, which is allowed and is in fact exactly what the material is for —
/// this is the navigation layer floating over content, not a skin on the content itself (see
/// `IskraDesign/Glass.swift`). The lifted message underneath is left as it always was: an
/// opaque bubble, because it is still content.
///
/// The pieces:
///
/// - `MessageMenuPresenter` — the one open menu, held above the whole app so the lifted message
///   is not trapped inside the scroll view it came from.
/// - `MessageMenuLayout` — where the thing goes on screen. Pure arithmetic, and tested.
/// - `MessageMenuHost` — what goes *around* a bubble: the press that opens it, the right-click
///   on a Mac, and the confirmations the items lead to.
/// - `MessageMenuOverlay` — the drawing of it.
enum MessageMenu {
    /// The coordinate space every anchor is measured in, installed by `messageMenuLayer()` at
    /// the root of the app. A message reports where it is in *this* space, so the overlay can
    /// put a copy of it in exactly the same place before lifting it.
    static let space = "iskra.messageMenu"

    /// Between the message and the things around it.
    static let gap = Theme.Spacing.close

    /// And between the whole arrangement and the edge of the screen.
    static let margin = Theme.Spacing.roomy
}

// MARK: - What is in the menu

/// One line of the menu.
struct MessageMenuAction: Identifiable {
    enum Manner {
        case ordinary
        /// Red, and at the bottom: deleting, reporting, blocking.
        case destructive
        /// Not a button at all — a line that says something. When the message was sent, when it
        /// was taken back. Drawn quiet and left unpressable, because there is nothing to press.
        case fact
    }

    let id = UUID()
    let title: LocalizedStringResource
    let systemImage: String
    var manner: Manner = .ordinary
    var perform: () -> Void = {}
}

/// A run of lines with a rule under it — the same grouping a `Section` gives a system menu.
struct MessageMenuSection: Identifiable {
    let id = UUID()
    let actions: [MessageMenuAction]
}

/// One open menu, and everything it needs to draw itself.
struct MessageMenuPresentation: Identifiable {
    /// The message's own ID, so re-presenting the same message is the same presentation and
    /// the animation does not start over.
    let id: String

    /// Where the message is on screen, in `MessageMenu.space`.
    let anchor: CGRect

    /// Which side of the conversation it is anchored to. The menu opens under the same edge,
    /// so it reads as belonging to the message rather than to the screen.
    let isOwn: Bool

    /// Whether the bar of emoji is offered at all. A deleted message keeps its menu — the two
    /// dates at the foot of it are the only things left that anybody presses it to ask — but a
    /// reaction on a redacted event is a 👍 under the words "message deleted". See
    /// `Message.canReact`.
    let canReact: Bool

    /// The emoji this person has already left on the message, so the bar can show them lit and
    /// pressing one of them takes it back.
    let mine: Set<String>

    /// The message, exactly as the conversation draws it. Handed over as a closure's result
    /// rather than snapshotted: what lifts off the page is the real view, so a video note goes
    /// on playing and a picture is a picture rather than a photograph of one.
    let content: AnyView

    let sections: [MessageMenuSection]

    let onReaction: (String) -> Void
}

/// The one menu that is open, if any.
///
/// Held by `messageMenuLayer()` at the root of the app rather than by the row, and that is the
/// whole reason this type exists. A menu drawn by the row would be drawn *inside* the scroll
/// view: clipped by it, scrolling with it, and unable to darken the toolbar above it. Lifting
/// the message means lifting it out of the list, which means somebody above the list has to be
/// holding it.
@MainActor
@Observable
final class MessageMenuPresenter {
    private(set) var presentation: MessageMenuPresentation?

    /// Bumped every time a menu opens, purely to knock the phone — `sensoryFeedback` fires on a
    /// change, and "a menu opened" is otherwise not one when the value it is watching is an
    /// optional that was already non-nil.
    private(set) var lifts = 0

    /// The message that is out of its place in the conversation — the one whose row is drawn
    /// empty, because it is in the menu.
    ///
    /// Not the same as `presentation?.id`, and the difference is the landing. Telegram does not lay
    /// a copy of the message over the original; it *takes the message out* of the list, and the
    /// list has a gap where it was until it comes back. Here the thing in the menu is a second
    /// drawing of the same message (SwiftUI cannot move one view between two parents), so the
    /// original is hidden while it is away — and hidden for exactly as long as the trip home
    /// takes, not merely while the menu is open. Shown again the moment the menu closed, it would
    /// stand in its place while the copy was still flying back to it: two of the same message for
    /// a third of a second, which is the very thing this is here to stop.
    private(set) var liftedID: String?

    /// Whether the message has *arrived* in the menu — the one number the whole flight runs on.
    ///
    /// False, the overlay draws the arrangement with the message standing exactly where it stood
    /// in the conversation: the bar folded into its corner, the verbs folded into theirs, the
    /// curtain clear. True, everything is where the menu wants it. Opening is two steps: the menu
    /// appears in the first state, and a frame later this is sprung to true; closing springs it
    /// back, and only when the message has landed is the presentation let go.
    ///
    /// It used to be a `.transition` on the arrangement, and a transition is a promise SwiftUI
    /// keeps only for the view that is actually inserted. Here that view was a container *around*
    /// the arrangement, the transition sat on its child, and SwiftUI quietly did not run it — so
    /// the menu simply appeared, with the message already at its destination: no flight at all,
    /// which is the whole of what Telegram's menu is. A plain value being animated has nothing to
    /// be quietly not run.
    private(set) var isOut = false

    /// Whether the message is on its way home — the menu is still drawn, but it is going.
    private var isClosing = false

    func present(_ presentation: MessageMenuPresentation) {
        guard self.presentation?.id != presentation.id || isClosing else { return }
        lifts += 1
        isClosing = false

        // All of it without animation: the row empties in the same frame the copy appears over
        // it, standing exactly in its place, so there is never a frame with both and never one
        // with neither.
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) {
            liftedID = presentation.id
            isOut = false
            self.presentation = presentation
        }

        // And then it flies — a frame later, so that the place it flies *from* has been drawn
        // once. Set in the same frame, SwiftUI would see only the destination.
        let id = presentation.id
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Theme.Timing.aFrame)
            guard let self, self.presentation?.id == id, !self.isClosing else { return }
            withAnimation(Theme.Timing.menuOpens) { self.isOut = true }
        }
    }

    func dismiss() {
        guard presentation != nil, !isClosing else { return }
        isClosing = true
        let id = presentation?.id

        withAnimation(Theme.Timing.menuCloses) {
            isOut = false
        } completion: { [weak self] in
            // Only if nothing else has been lifted in the meantime — a second message pressed
            // while the first was still on its way home owns the menu, and the gap, now.
            guard let self, self.isClosing, self.presentation?.id == id else { return }
            self.isClosing = false
            self.presentation = nil
            self.liftedID = nil
        }
    }
}

public extension EnvironmentValues {
    /// The message menu, installed once at the root of the app. Nil is not a state the app is
    /// ever in — see `messageMenuLayer()` — but it is left optional so a preview of a single
    /// row is not a crash.
    @Entry internal var messageMenu: MessageMenuPresenter?
}

// MARK: - Where it goes

/// Working out where on screen the lifted message, the bar above it and the list below it go.
///
/// Pure arithmetic, in its own type, because it is the part of a context menu that is actually
/// *hard* — everything else is a rounded rectangle. There are four things it has to be true of
/// at once: the message should stay as near as possible to where the finger left it, the whole
/// column has to fit between the safe areas, a message taller than the screen has to scroll
/// rather than push the menu off the bottom, and the menu has to open under the edge the
/// message is anchored to — at one width, which is deliberately not the pressed message's.
/// Being a struct of numbers, it can be tested — see
/// `MessageMenuLayoutTests`.
struct MessageMenuLayout: Equatable {
    /// Top-left of the whole arrangement, in `MessageMenu.space`.
    var origin: CGPoint

    /// How wide the arrangement is. One number for every message in the app — see
    /// `Theme.Size.menuWidth` — and only ever narrowed, on a screen too narrow to hold it.
    ///
    /// It used to grow to the width of the message, so that a menu under a long paragraph came
    /// out wide and the same menu under "ок" came out narrow. The verbs in it are identical
    /// either way, which is the argument: a menu whose width is set by the thing it was opened
    /// on is a different shape every time it opens, and the eye has to find the same six words
    /// in a new place on each press. Fixed, the list is somewhere the hand already knows — and
    /// the lifted message above it is still free to be as wide as it is, because it is given
    /// its own width and not this one (see `MessageMenuOverlay.lifted`).
    var width: CGFloat

    /// How wide the grid of every emoji is, when the "+" has opened it. Wider than the rest of
    /// the menu — it is a grid and not a column of words, see `Theme.Size.emojiPanelWidth` — and
    /// never wider than the screen has room for. Fixed for the same reason `width` is.
    var emojiWidth: CGFloat

    /// And how far it has to slide to stay on screen at that width.
    ///
    /// The panel hangs from the same edge as everything else in the menu — the message's right
    /// if the message is yours, its left if it is not — so a panel half again as wide as the
    /// column grows away from that edge, and on a message near the far side of the screen it
    /// grows straight off it. This is the correction, measured from where the panel would
    /// naturally sit, and it is zero for every message that is not near an edge.
    var emojiOffset: CGFloat

    /// How tall the lifted message is allowed to be. Its own height, unless it is a very long
    /// message on a very short screen — and then it keeps its size and *scrolls* inside this
    /// height, rather than being shrunk to fit, which is what it used to do. A shrunken page of
    /// text is a page nobody can read, and reading it is often why the menu was opened.
    var contentHeight: CGFloat

    /// The most the list of actions may take. Beyond that it scrolls — a menu with eleven items
    /// on an iPhone SE with a tall message above it is a real arrangement, not a hypothetical.
    var listMaxHeight: CGFloat

    /// How far the lifted message is from where it stood in the conversation — the distance the
    /// whole arrangement travels on its way in and back on its way out.
    ///
    /// Telegram does not fade a menu up over the message it is about; it *picks the message up*:
    /// the bubble leaves its place in the list and springs to wherever the menu needs it, the verbs
    /// growing out of its corner as it goes, and on closing it springs back down into the gap it
    /// left. Most of the time this is nothing at all — the menu puts the message exactly where it
    /// was — and it is a real distance only for a message near the top or bottom of the screen,
    /// which is exactly the one that otherwise appeared to jump.
    var lift: CGSize = .zero

    /// A message is never given less height than this. Past it the window onto the message is too
    /// small to read through,
    /// and an unreadable message with a menu under it is worse than a menu that scrolls.
    static let leastContentHeight: CGFloat = Theme.Size.menuRow * 2

    /// - Parameters:
    ///   - anchor: where the message is, in `MessageMenu.space`.
    ///   - region: the part of the window the menu may use — the safe area, in that same space.
    ///     Taking a rectangle rather than a size and a set of insets is what makes the sums
    ///     below plain arithmetic: everything is in one space, and the answer comes back in the
    ///     region's own coordinates, ready to be offset from its top-left corner.
    static func resolve(anchor rect: CGRect,
                        region: CGRect,
                        isOwn: Bool,
                        aboveHeight: CGFloat,
                        listHeight: CGFloat) -> MessageMenuLayout {
        let gap = MessageMenu.gap
        let margin = MessageMenu.margin

        let anchor = rect.offsetBy(dx: -region.minX, dy: -region.minY)
        let container = region.size

        // One width, whatever was pressed. Narrowed only where the screen cannot hold it.
        let width = min(Theme.Size.menuWidth, max(0, container.width - margin * 2))

        let top = margin
        let bottom = container.height - margin
        let available = max(0, bottom - top)

        // The message gives first. It is the one part of the column whose height is not a
        // decision — the bar is a bar and the verbs are the verbs, but a message is however
        // long somebody wrote it.
        let roomForContent = available - aboveHeight - listHeight - gap * 2
        let allowed = max(leastContentHeight, roomForContent)
        let contentHeight = min(anchor.height, allowed)

        // And only when the message has given everything it can does the list start scrolling.
        let listMaxHeight = max(Theme.Size.menuRow,
                                min(listHeight, available - aboveHeight - contentHeight - gap * 2))
        let columnHeight = aboveHeight + gap + contentHeight + gap + listMaxHeight

        // Vertically: where the message already is, moved only as far as it has to be.
        let wanted = anchor.minY - aboveHeight - gap
        let lowest = bottom - columnHeight
        let y = lowest > top ? min(max(wanted, top), lowest) : top

        // Horizontally: under the edge the message hangs from — its right if it is yours, its
        // left if it is not — and never past the margin.
        let wantedX = isOwn ? anchor.maxX - width : anchor.minX
        let furthestX = max(margin, container.width - margin - width)
        let x = min(max(wantedX, margin), furthestX)

        // The emoji grid, which is the one part of the menu that is wider than the rest. Same
        // anchored edge, same margins — only the width differs, so the sum is the same sum.
        let emojiWidth = min(Theme.Size.emojiPanelWidth, max(0, container.width - margin * 2))
        let wantedEmojiX = isOwn ? x + width - emojiWidth : x
        let furthestEmojiX = max(margin, container.width - margin - emojiWidth)
        let emojiX = min(max(wantedEmojiX, margin), furthestEmojiX)

        // Where the lifted message ends up, against where it was. It sits under the bar when there
        // is one (and the gap after it), and it hangs from its own edge of the column — its right if
        // it is yours, its left if it is not — so that is the edge measured.
        let liftedY = y + (aboveHeight > 0 ? aboveHeight + gap : 0)
        let liftedEdge = isOwn ? x + width : x
        let anchorEdge = isOwn ? anchor.maxX : anchor.minX

        return MessageMenuLayout(origin: CGPoint(x: x, y: y),
                                 width: width,
                                 emojiWidth: emojiWidth,
                                 emojiOffset: emojiX - wantedEmojiX,
                                 contentHeight: contentHeight,
                                 listMaxHeight: listMaxHeight,
                                 lift: CGSize(width: anchorEdge - liftedEdge,
                                              height: anchor.minY - liftedY))
    }
}

// MARK: - The layer

extension View {
    /// Installs the message menu above the whole app: the coordinate space anchors are measured
    /// in, the presenter rows report to, and the overlay the menu is drawn in.
    ///
    /// It goes on once, at the root — `IskraRootView` — and not on the room. On the room it
    /// would be inside the navigation stack, so the lifted message would stop at the toolbar
    /// and the conversation behind it would darken while the bar above it stayed bright.
    func messageMenuLayer() -> some View {
        modifier(MessageMenuLayer())
    }
}

private struct MessageMenuLayer: ViewModifier {
    @State private var presenter = MessageMenuPresenter()

    func body(content: Content) -> some View {
        content
            .environment(\.messageMenu, presenter)
            .coordinateSpace(.named(MessageMenu.space))
            .overlay { MessageMenuOverlay(presenter: presenter) }
    }
}
