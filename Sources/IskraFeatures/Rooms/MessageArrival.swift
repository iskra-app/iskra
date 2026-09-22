import SwiftUI
import IskraDesign

/// A message rising into place, animated by the row itself.
///
/// **Why this is not a `.transition`.** SwiftUI plays a transition only when the change that
/// inserted the view happened inside an animated transaction, so a transition needs an
/// `.animation` scope around the list to drive it — and an implicit scope animates *every*
/// animatable value in everything it wraps whenever the one value it watches changes. Around a
/// conversation that means a delivery tick, a reaction, an edit or a redaction is animated
/// because something unrelated moved in the same pass. That bug was chased three times under
/// three different values — the tail of the list, the send queue, the end of the conversation —
/// and each of them animated the wrong thing, because what a scope watches is never what it
/// animates.
///
/// A row that animates its own entrance needs no transaction from anybody. The animation here is
/// scoped to one piece of state in one row, and nothing else in the conversation can be caught
/// by it. That is the whole design: the list has no animation scope at all, and cannot acquire
/// one by accident.
///
/// **Why an offset and not a height.** The row takes its full height the instant it exists and
/// only its *picture* slides, so the conversation is exactly as tall during the animation as it
/// is after it. Growing the height over a third of a second would change the content size a
/// dozen times, and every one of those is a size change the scroll view answers: the reader
/// standing halfway up a busy room would watch it drift under them while a message they cannot
/// even see arrives below. See the `held` metrics in `RoomView`.
///
/// **Up, from the bottom.** The end of the conversation is at the foot of the screen, so that is
/// where a new message comes from — out of the composer, settling into the row it now owns.
private struct MessageArrival: ViewModifier {
    /// Whether this row is genuinely arriving. False for everything else, and then the row is
    /// drawn in place, at full strength, and `onAppear` does nothing.
    ///
    /// It has to be false for the ordinary case, and not merely "not animated". A `LazyVStack`
    /// builds a row when it scrolls into view, so a row that animated itself on appearing would
    /// animate every time the reader scrolled past it. `RoomView` decides — only rows added past
    /// the end of the conversation are arriving — and it decides while the view is being built,
    /// which is the only moment early enough to matter.
    let isArriving: Bool

    /// How far below its place the message starts. Small on purpose: this is a message being put
    /// down, not one flying in from off-screen.
    private static let rise: CGFloat = 14

    /// Where the row is, and how solid — held as state rather than read from `isArriving`,
    /// because `isArriving` is true for exactly one pass and the animation outlives it.
    ///
    /// This is the whole of what went wrong the first time. The modifier branched on
    /// `isArriving`, so the row was one view while arriving and a different one after — and
    /// "after" is the *next* pass, a few milliseconds later, once `RoomView` has written down
    /// where the conversation now ends. SwiftUI duly tore down the animating branch and built
    /// the plain one in its place, which cancelled the animation before a single frame of it was
    /// drawn. A message you sent simply appeared, with nothing to show for it.
    ///
    /// Seeded at `init` instead. A `@State` initial value is used on the first build and then
    /// left alone, so the row starts low and clear, lands once, and stays landed no matter what
    /// the flag does afterwards. One view throughout, and nothing to tear down.
    @State private var lift: CGFloat
    @State private var solidity: Double

    init(isArriving: Bool) {
        self.isArriving = isArriving
        _lift = State(initialValue: isArriving ? Self.rise : 0)
        _solidity = State(initialValue: isArriving ? 0 : 1)
    }

    func body(content: Content) -> some View {
        content
            .offset(y: lift)
            .opacity(solidity)
            .onAppear {
                guard isArriving else { return }
                // The animation lives on the change, inside the row, and reaches nothing
                // outside it.
                withAnimation(Theme.Timing.arrival) {
                    lift = 0
                    solidity = 1
                }
            }
    }
}

extension View {
    /// A message rising into place — see `MessageArrival`, which explains why the one animation
    /// left in a conversation belongs to the row and not to the list.
    func arrives(_ isArriving: Bool) -> some View {
        modifier(MessageArrival(isArriving: isArriving))
    }
}
