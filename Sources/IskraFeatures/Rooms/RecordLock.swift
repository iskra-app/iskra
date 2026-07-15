import SwiftUI
import IskraDesign

/// The target of the swipe up: reach it, and the recording carries on without the finger.
///
/// The gesture existed before this did, and that was the bug. Swiping up locked the recording
/// perfectly well — and said nothing about it. Nothing appeared, nothing moved, nothing was
/// confirmed, so the only way to find out whether the app had taken the lock was to let go of
/// the button and see whether the message had been sent. Which is not a test anybody can run
/// twice: letting go *is* sending, and the answer to "did that lock?" was a voice message in a
/// room, every time it was no.
///
/// So the thumb now has somewhere to go and something to watch on the way. The pill appears
/// above the record button when the hold begins; the accent rises up it as the finger climbs;
/// and at the top the lock closes, the pill jumps, and the phone taps back. The recording is
/// then hands-free, and the user knows it is, which is the entire point.
///
/// It is drawn twice — once in the composer, for a spoken message, and once in the camera
/// overlay, where the composer is behind a blur and the pill has to be redrawn above the shutter
/// that stands in the same place. Hence `onCamera`, and hence its living in a file of its own:
/// it belongs to neither caller, exactly as `RecordingStrip` does.
/// The swipe up, as every view that has to draw it needs to see it.
///
/// One value and not three flags, and it is published by the composer as one — which matters,
/// because two of the three change in the same instant. The lock catching sets `hasLocked` and
/// takes the finger off the button in one movement, and a camera overlay that worked those out
/// separately would spend a frame believing neither had happened and blink its pill out of
/// existence on exactly the movement it exists to celebrate.
struct LockGesture: Equatable {
    /// How far the thumb has climbed, 0 to 1, where 1 is `Theme.Size.gestureReach` and the lock.
    var reach: Double = 0

    /// Whether there is anything to draw: a hold on its way somewhere, or a lock just caught.
    var isVisible: Bool = false

    /// It caught. True for a moment afterwards — the pill is the only place the confirmation can
    /// live, because everything else on the screen looks exactly the same locked as it does held.
    var hasLocked: Bool = false
}

struct RecordLock: View {
    let gesture: LockGesture

    /// Over the camera rather than in the composer, which decides what it is made of — glass in
    /// the navigation layer, an opaque dark fill on a backdrop that is already blurred. The same
    /// rule, and the same reasoning, as `RecordingStrip.onCamera`.
    var onCamera: Bool = false

    @Environment(\.accent) private var accent

    private var reach: Double { gesture.reach }
    private var isLocked: Bool { gesture.hasLocked }

    /// How much of the pill the accent has climbed — the whole of it, once the lock has caught.
    private var filled: CGFloat {
        (isLocked ? 1 : reach) * Theme.Size.recordLock.height
    }

    var body: some View {
        surface
            .overlay { glyphs }
            .scaleEffect(isLocked ? 1.15 : 1)
            .animation(.bouncy(duration: 0.35), value: isLocked)
            // Nothing here is reachable by VoiceOver and nothing here needs to be: a swipe is not
            // a gesture VoiceOver performs, and the record button already offers what it does as
            // actions. A pill that announced itself would be announcing a road with no way onto it.
            .accessibilityHidden(true)
    }

    /// The accent climbing the pill *is* the swipe, drawn.
    ///
    /// A `Rectangle` rising inside a clipped capsule rather than a capsule that grows: a growing
    /// capsule keeps its round bottom and reads as a separate little object sliding up a tube,
    /// which is a thing moving. This is the tube filling, which is a thing being reached.
    private var surface: some View {
        ZStack(alignment: .bottom) {
            Color.clear

            Rectangle()
                .fill(accent.color)
                .frame(height: filled)
        }
        .frame(width: Theme.Size.recordLock.width, height: Theme.Size.recordLock.height)
        .modifier(LockSurface(onCamera: onCamera))
    }

    /// The lock and the arrow, drawn twice — once in the colour they wear against the pill, and
    /// once in the colour they wear against the accent, with the second copy masked to exactly
    /// the part of the pill the accent has climbed.
    ///
    /// Twice, because a single copy cannot be right. Colouring the pair by how far the swipe has
    /// come turns the lock white while the fill is still below it — a white lock on clear glass,
    /// which is no lock at all — and leaving them dark drowns the arrow the moment the accent
    /// arrives underneath it. The two glyphs are not in the same place, so they cannot take the
    /// same answer. Masking is what asks the question per pixel instead of per view: the accent
    /// carries its own foreground colour up the pill with it, and every glyph it reaches changes
    /// as it is reached.
    private var glyphs: some View {
        ZStack {
            marks.foregroundStyle(onCamera ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))

            marks
                .foregroundStyle(accent.foreground)
                .mask(alignment: .bottom) {
                    Rectangle().frame(height: filled)
                }
        }
        .frame(width: Theme.Size.recordLock.width, height: Theme.Size.recordLock.height)
    }

    private var marks: some View {
        VStack(spacing: Theme.Spacing.tight) {
            Image(systemName: isLocked ? "lock.fill" : "lock.open.fill")
                .font(.footnote.weight(.semibold))
                .symbolEffect(.bounce, value: isLocked)

            // The arrow fades out as the thumb arrives, because by then it has been obeyed.
            Image(systemName: "chevron.up")
                .font(.caption2.weight(.bold))
                .opacity(isLocked ? 0 : 1 - reach)
        }
        .animation(.smooth(duration: 0.15), value: isLocked)
    }
}

/// Glass in the composer, an opaque dark fill over the camera — applied *to* the pill and never
/// laid behind it, for the reason `RecordingStrip` sets out at length: glass reached through a
/// `.background` is still collected by an enclosing `GlassEffectContainer`, which then draws it
/// in its own pass, on top of the thing it was supposed to be sitting behind.
private struct LockSurface: ViewModifier {
    let onCamera: Bool

    func body(content: Content) -> some View {
        if onCamera {
            content
                .background(Capsule().fill(.black.opacity(Theme.Backdrop.dim)))
                .clipShape(.capsule)
        } else {
            content
                .navigationGlass(in: .capsule)
                .clipShape(.capsule)
        }
    }
}

#Preview("Reaching") {
    VStack(spacing: 24) {
        RecordLock(gesture: LockGesture(reach: 0, isVisible: true))
        RecordLock(gesture: LockGesture(reach: 0.5, isVisible: true))
        RecordLock(gesture: LockGesture(reach: 1, isVisible: true, hasLocked: true))
    }
    // Room around the previewed control in the canvas — scaffolding that never ships, so it does
    // not answer to the Theme rule the way a real view does.
    // swiftlint:disable:next hardcoded_layout_metric
    .padding(40)
}
