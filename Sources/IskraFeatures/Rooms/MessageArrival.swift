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
                land()
            }
    }

    /// Starts the rise, one frame after the row exists.
    ///
    /// The frame is the point. `onAppear` runs inside the same pass that first lays the row out,
    /// so animating from there gives SwiftUI a view whose initial value it has never drawn — and
    /// it does the sensible thing with that, which is to collapse the two into a single render
    /// and put the row straight at its final place. The animation was correct and simply had no
    /// frames to happen in: a message appeared, fully formed, exactly as though nothing had been
    /// asked for.
    ///
    /// So the row is drawn once where it starts, low and clear, and the landing is asked for
    /// after that. One frame is all it takes, and one frame is not a delay anybody can see —
    /// `onAppear` has already put the bubble on screen; this only decides where it is standing
    /// when the eye arrives.
    private func land() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(16))
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
