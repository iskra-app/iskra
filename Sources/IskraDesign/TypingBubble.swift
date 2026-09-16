import SwiftUI

/// The three dots that say someone is writing, in an incoming bubble on the leading edge — the same
/// shape a message from them would arrive in, so it reads as a message not yet finished rather than
/// as a piece of chrome.
///
/// "The same shape" is meant literally, and it was not. The dots used to carry `Spacing.normal` of
/// padding of their own *inside* the padding `messageBubble` already spends, which made the bubble
/// twenty-four points taller than a one-line message — tall enough that `BubbleShape`'s corner
/// radius stopped being clamped, so the typing bubble came out a rounded rectangle sitting under a
/// column of capsules. The extra padding is gone, and the height now comes from the one honest
/// source there is for it: a line of the same body text the messages are set in, laid out and then
/// drawn as nothing. A hard-coded height would be right at the default Dynamic Type size and wrong
/// at every other one.
///
/// The dots pulse in a staggered wave, iMessage's timing: a gentle rise and fall, never a hard
/// blink. It is driven by a repeating animation on a single `@State` flag, **not** by
/// `TimelineView(.animation)` — and that difference is load-bearing. `TimelineView(.animation)`
/// rebuilds its body every frame, and this bubble lives inside the conversation's `ScrollView`,
/// whose `onScrollGeometryChange` writes state; the two together drove SwiftUI into "tried to update
/// multiple times per frame" and hung the app. A `.repeatForever` animation runs on the render
/// server instead, animating opacity and scale without rebuilding the view — so it costs the scroll
/// observer nothing.
public struct TypingBubble: View {
    public init() {}

    @State private var pulsing = false

    private let dot = Theme.Spacing.close          // 8
    private let spacing = Theme.Spacing.tight      // 4

    /// One full pulse, and how far each dot lags the one before it.
    private let period = 0.6
    private let stagger = 0.18

    public var body: some View {
        HStack(spacing: 0) {
            // A line of body text, laid out and then given no width at all. It is here for its
            // *height* and nothing else: the bubble is exactly as tall as a bubble with one line
            // of words in it, at whatever type size the reader has chosen, and the corner radius
            // is therefore clamped to exactly the same capsule.
            Text(verbatim: "Ж")
                .font(.body)
                .lineLimit(1)
                .fixedSize()
                .frame(width: 0)
                .hidden()

            HStack(spacing: spacing) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(.secondary)
                        .frame(width: dot, height: dot)
                        // Opacity and scale are render transforms — they do not change the bubble's
                        // layout size, so the scroll view's content height stays put frame to frame.
                        .opacity(pulsing ? 1 : 0.35)
                        .scaleEffect(pulsing ? 1.0 : 0.8)
                        .animation(
                            .easeInOut(duration: period)
                                .repeatForever(autoreverses: true)
                                .delay(Double(index) * stagger),
                            value: pulsing
                        )
                }
            }
        }
        .messageBubble(.incoming)
        .onAppear { pulsing = true }
        // Decorative: VoiceOver hears "typing" from the room's header subtitle, which names *who*.
        // Two announcements of the same fact — one of them wordless dots — is one too many.
        .accessibilityHidden(true)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
