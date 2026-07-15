import SwiftUI

/// The three dots that say someone is writing, in an incoming bubble on the leading edge — the same
/// shape a message from them would arrive in, so it reads as a message not yet finished rather than
/// as a piece of chrome.
///
/// The dots pulse in a wave, iMessage's timing: a gentle rise and fall staggered across the three,
/// never a hard blink. It is driven by `TimelineView(.animation)` rather than a repeating animation
/// on `@State`, so it needs no lifecycle to start or stop — it animates while it is on screen and
/// costs nothing when it is not, and appearing and leaving is left to whoever shows it, with a soft
/// transition.
public struct TypingBubble: View {
    public init() {}

    private let dot = Theme.Spacing.close          // 8
    private let spacing = Theme.Spacing.tight      // 4

    public var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: spacing) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(.secondary)
                        .frame(width: dot, height: dot)
                        .opacity(level(t, index))
                        .scaleEffect(0.8 + 0.35 * level(t, index))
                }
            }
            .padding(.horizontal, Theme.Spacing.normal)
            .padding(.vertical, Theme.Spacing.normal)
            .messageBubble(isOwn: false)
        }
        // Decorative: VoiceOver hears "typing" from the room's header subtitle, which names *who*.
        // Two announcements of the same fact — one of them wordless dots — is one too many.
        .accessibilityHidden(true)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    /// A staggered pulse in 0.35…1.0 — each dot a beat behind the one before it, so the light runs
    /// left to right and back rather than the three flashing together.
    private func level(_ time: TimeInterval, _ index: Int) -> Double {
        let wave = sin(time * 3.4 - Double(index) * 0.9)
        return 0.35 + 0.65 * (wave * 0.5 + 0.5)
    }
}
