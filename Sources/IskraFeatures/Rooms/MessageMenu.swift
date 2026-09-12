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

    func present(_ presentation: MessageMenuPresentation) {
        guard self.presentation?.id != presentation.id else { return }
        lifts += 1
        withAnimation(Theme.Timing.menuOpens) { self.presentation = presentation }
    }

    func dismiss() {
        guard presentation != nil else { return }
        withAnimation(.smooth(duration: Theme.Timing.chrome)) { presentation = nil }
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
/// column has to fit between the safe areas, a message taller than the screen has to give way
/// rather than push the menu off the bottom, and the menu has to open under the edge the
/// message is anchored to. Being a struct of numbers, it can be tested — see
/// `MessageMenuLayoutTests`.
struct MessageMenuLayout: Equatable {
    /// Top-left of the whole arrangement, in `MessageMenu.space`.
    var origin: CGPoint

    /// How wide the arrangement is: the list's width, or the message's if the message is wider.
    var width: CGFloat

    /// How much the lifted message is shrunk to make room. 1 unless it is a very long message
    /// on a very short screen.
    var contentScale: CGFloat

    /// The most the list of actions may take. Beyond that it scrolls — a menu with eleven items
    /// on an iPhone SE with a tall message above it is a real arrangement, not a hypothetical.
    var listMaxHeight: CGFloat

    /// A message never shrinks below this. Past it the thing being lifted stops being legible,
    /// and an illegible message with a menu under it is worse than a menu that scrolls.
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

        let width = min(max(Theme.Size.menuWidth, anchor.width),
                        max(0, container.width - margin * 2))

        let top = margin
        let bottom = container.height - margin
        let available = max(0, bottom - top)

        // The message gives first. It is the one part of the column whose height is not a
        // decision — the bar is a bar and the verbs are the verbs, but a message is however
        // long somebody wrote it.
        let roomForContent = available - aboveHeight - listHeight - gap * 2
        let allowed = max(leastContentHeight, roomForContent)
        let contentScale = anchor.height > 0 ? min(1, allowed / anchor.height) : 1
        let contentHeight = anchor.height * contentScale

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

        return MessageMenuLayout(origin: CGPoint(x: x, y: y),
                                 width: width,
                                 contentScale: contentScale,
                                 listMaxHeight: listMaxHeight)
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
