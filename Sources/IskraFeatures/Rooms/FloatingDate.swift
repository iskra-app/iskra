import SwiftUI
import IskraDesign

/// The date that floats over the top of a conversation while it is being scrolled — Telegram's.
///
/// Scroll quickly through a week of messages and the dates go past faster than they can be read;
/// the one you are *in* is somewhere above, off the screen. Telegram keeps it pinned under the title
/// for as long as the list is moving, and lets it fade once the list comes to rest (0.3 s in, 0.4 s
/// out — `ChatMessageDateHeader.updateFlashing`). Resting, it is noise: the reader is reading, and the
/// date of what they are reading is a glance up away.
///
/// Worked out without asking where every row is. Each date in the conversation says only when it
/// passes above the line (`DayDividerView`), and the date floating is the latest of those above it —
/// the day whose messages are the ones on the screen. A date that has scrolled so far up that the
/// list has let go of its view never reports coming back down, and that is correct: it is still
/// above.
struct FloatingDates: Equatable {
    private(set) var above: Set<Date> = []

    /// The day the reader is in, or nil while every date is still below the line — the top of the
    /// conversation is on the screen, and its own date is there to be read.
    var current: Date? { above.max() }

    mutating func date(_ date: Date, isAbove: Bool) {
        if isAbove { above.insert(date) } else { above.remove(date) }
    }

    mutating func reset() {
        above.removeAll()
    }
}

/// The capsule itself. Glass, because it floats over the conversation as the title bar does, and is
/// part of the navigation layer rather than of what is being read.
struct FloatingDateLabel: View {
    let date: Date

    var body: some View {
        Text(DayDividerView.label(for: date))
            .font(.caption.weight(.medium))
            .padding(.horizontal, Theme.Spacing.normal)
            .padding(.vertical, Theme.Spacing.tight)
            .navigationGlass(in: .capsule)
            .padding(.top, Theme.Spacing.close)
            .allowsHitTesting(false)
            // Said once, when it changes, rather than on every pass — and it is the dividers, in the
            // list, that VoiceOver reads; this is a picture of one of them.
            .accessibilityHidden(true)
    }
}

extension EnvironmentValues {
    /// Where a date reports passing the top of the conversation. Nil outside a room — a peek, a
    /// search result — where nothing floats.
    @Entry var dayPassesTop: ((Date, Bool) -> Void)?

    /// How far down the scroll view the line is that a date counts as having passed: the top of
    /// what can be seen, under the title bar, plus the room the floating date itself takes.
    @Entry var floatingDateLine: CGFloat = 0
}
