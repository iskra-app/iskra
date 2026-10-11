import SwiftUI
import IskraDesign

/// A message arriving at the foot of the conversation, animated by the row itself — the way
/// Telegram does it.
///
/// **What Telegram does.** Its list does not slide a new message in over the others; it *opens a
/// place* for it. The new item's height goes from nothing to its own over 0.3 s, so every message
/// above is pushed up together by exactly as much as the newcomer needs, and the newcomer rises
/// into that gap from under the input field. Somebody else's message fades in as it comes (0.2 s);
/// one of yours does not fade, it *travels* — out of the text field where the words just were,
/// across to its own side of the screen, on a curve of its own (`ChatMessageTransitionNode`). The
/// effect is that nothing on the screen ever jumps: the column moves, smoothly, because something
/// was added to it.
///
/// **Why the height, here, and why that is not the mistake it used to be.** An earlier version of
/// this file argued the opposite — that growing the height would make the reader standing halfway up
/// a busy room watch the conversation drift under them while a message they could not even see
/// arrived below. That is true, and it is why the growth only ever happens when the reader is *at
/// the end* (`RoomView` decides — see `PlacedRow.arrives`). There the drift is the point: the end is
/// where the reader is looking, and the column moving up to make room is the arrival. Anywhere else
/// the row is simply there, at full height, and `RoomView.held` keeps the reader where they were.
///
/// **Why still not a `.transition`.** Everything the old note said about that stands: a transition
/// needs an animated transaction around the list, and an animated transaction around a conversation
/// animates every tick, reaction and edit that happens to land in the same pass. The animation is
/// still scoped to state inside one row — the fraction of its height it is claiming, how solid it is,
/// how far across it has come — and nothing outside the row can be caught by it.
struct MessageArrival: ViewModifier {
    /// How a row comes in. Decided by `RoomView` while the view is being built — see
    /// `MessageArrivals` — because a `LazyVStack` builds rows as they scroll into view, and a row
    /// that animated itself on appearing would animate every time the reader scrolled past it.
    enum Style {
        /// Already here: history, a refill, a row scrolled back into view.
        case still
        /// Somebody else's message: the column makes room and it fades up into it.
        case incoming
        /// One of ours: the column makes room and it travels across from the composer.
        case outgoing
    }

    let style: Style

    /// How much of its height the row is claiming, from 0 to 1. See `ClaimedHeight`.
    ///
    /// State, seeded at `init`, and never re-read from `style` — the lesson of the first version of
    /// this file, which branched on the flag and had the arriving branch torn down a few
    /// milliseconds later when `RoomView` recorded the new end, cancelling the animation before a
    /// single frame of it was drawn.
    @State private var claimed: CGFloat
    @State private var solidity: Double

    init(style: Style) {
        self.style = style
        _claimed = State(initialValue: style == .still ? 1 : 0)
        _solidity = State(initialValue: style == .incoming ? 0 : 1)
    }

    func body(content: Content) -> some View {
        // The sideways journey of one of ours is not here: it belongs to the *bubble*, not to the
        // row, because the row is as wide as the screen and its leading edge says nothing about
        // where the bubble starts. See `ComposerTravel`.
        ClaimedHeight(fraction: claimed) {
            content.opacity(solidity)
        }
        .onAppear {
            guard style != .still else { return }
            land()
        }
    }

    /// Starts the arrival, one frame after the row exists.
    ///
    /// The frame is not a delay anybody can see. `onAppear` runs inside the same pass that first lays
    /// the row out, and an animation asked for from there has no initial value on screen to start
    /// from — SwiftUI collapses the two into one render and the row simply appears. Drawn once where
    /// it starts (no height, below the fold), it then has somewhere to move from.
    private func land() {
        Task { @MainActor in
            try? await Task.sleep(for: Theme.Timing.aFrame)

            withAnimation(Theme.Timing.messageMakesRoom) { claimed = 1 }

            if style == .incoming {
                withAnimation(Theme.Timing.messageAppears) { solidity = 1 }
            }
        }
    }
}

/// One of our messages travelling across from the composer to its bubble — the sideways half of
/// Telegram's send animation. Put on the *bubble*, because it is the bubble's leading edge that has
/// to come from the text field's; the row around it spans the screen.
///
/// Measured once, before it moves, in screen coordinates against `composerTextLeading`. An offset
/// does not change the layout, so writing it from the measurement cannot feed back into the
/// measurement — `EnvironmentValues.timelineWidth` tells the story of a measurement that *did*.
struct ComposerTravel: ViewModifier {
    let isTravelling: Bool

    @State private var across: CGFloat = 0
    @State private var hasMeasured: Bool

    @Environment(\.composerTextLeading) private var composerTextLeading

    init(isTravelling: Bool) {
        self.isTravelling = isTravelling
        _hasMeasured = State(initialValue: !isTravelling)
    }

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minX } action: { minX in
                guard !hasMeasured else { return }
                hasMeasured = true
                guard let composerTextLeading else { return }

                // Only ever leftwards: a bubble of ours sits to the right of where it was typed.
                // Set without animation, then sent home on the next frame — see `MessageArrival.land`.
                var still = Transaction()
                still.disablesAnimations = true
                withTransaction(still) { across = min(0, composerTextLeading - minX) }

                Task { @MainActor in
                    try? await Task.sleep(for: Theme.Timing.aFrame)
                    withAnimation(Theme.Timing.messageCrosses) { across = 0 }
                }
            }
            .offset(x: across)
    }
}

/// Lays its one child out at full size and claims only `fraction` of its height from the column.
///
/// The child is placed from the *top* of the claimed space, so while the claim is small the rest of
/// it hangs below — under the composer, off the end of the conversation — and as the claim grows it
/// rises into view. That is Telegram's arrival, made of two facts: the column is pushed up by the
/// claim, and the message comes up out of where you type. Animatable, so SwiftUI drives the claim
/// frame by frame rather than jumping it.
struct ClaimedHeight: Layout {
    var fraction: CGFloat

    var animatableData: CGFloat {
        get { fraction }
        set { fraction = newValue }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let size = child.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: size.width, height: size.height * min(1, max(0, fraction)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin,
                              anchor: .topLeading,
                              proposal: ProposedViewSize(width: bounds.width, height: nil))
    }
}

extension EnvironmentValues {
    /// The leading edge of the composer's text, in screen coordinates — where a message of ours
    /// starts its journey across to its bubble. Nil wherever there is no composer (a peek, a
    /// preview), and then a message of ours simply rises without travelling.
    @Entry var composerTextLeading: CGFloat?
}

extension View {
    /// A message arriving — see `MessageArrival`.
    func arrives(_ isArriving: Bool, outgoing: Bool) -> some View {
        modifier(MessageArrival(style: !isArriving ? .still : outgoing ? .outgoing : .incoming))
    }

    /// A bubble of ours coming across from the composer — see `ComposerTravel`.
    func travelsFromComposer(_ isTravelling: Bool) -> some View {
        modifier(ComposerTravel(isTravelling: isTravelling))
    }
}

extension AnyTransition {
    /// An arrival for a view that genuinely is inserted and removed: the typing bubble.
    ///
    /// `MessageArrival` exists because rows must *not* be animated by the list. The typing bubble is
    /// the exception that proves it: it is not a row, it has no identity to hold on to, and it leaves
    /// again, so there is nothing to carry an entrance of its own. It gets a transition instead,
    /// driven by an `.animation` scope that wraps the bubble and nothing else.
    static var arrival: AnyTransition {
        .offset(y: MessageArrival.rise).combined(with: .opacity)
    }
}

extension MessageArrival {
    /// How far below its place the typing bubble starts. Small on purpose: it is a message that has
    /// not been finished yet, put down rather than flown in.
    static let rise: CGFloat = 14
}

/// Which rows at the end of a conversation are arriving, and which were merely added to it.
///
/// Pulled out of `RoomView` and given a name so it can be *tested*. The rule has been wrong
/// three times — first "anything new", then "anything new after a delay", then this — and every
/// one of those was found by a person looking at a screen, which is a slow and unreliable way to
/// learn that a page of history counted as fifteen people speaking at once.
enum MessageArrivals {
    /// The index of the first arriving row, or `rows.count` when nothing is arriving.
    ///
    /// The test is *where*, not *when*. History is added above what is already there; a message
    /// is added past the end of it. So a row is arriving only if it comes after the row that was
    /// last on the previous pass — and if that row is gone, nothing is: the conversation was
    /// rebuilt, or a local echo has just been given its real identity by the server, and neither
    /// is somebody speaking.
    static func firstArriving(in ids: [String], after newest: String?) -> Int {
        guard let newest, let end = ids.lastIndex(of: newest) else { return ids.count }
        return end + 1
    }
}
