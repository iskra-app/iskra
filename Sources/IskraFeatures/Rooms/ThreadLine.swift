import SwiftUI
import IskraCore
import IskraDesign

/// The line under a message that has been answered in a thread: how many answers, and who said
/// the last one and what. Pressed, it opens the thread — see `RoomView.openedThread`.
///
/// In the accent, as a link is: it is the one thing under a bubble that goes somewhere.
struct ThreadLine: View {
    let thread: ThreadSummaryPreview
    let onOpen: () -> Void

    @Environment(\.accent) private var accent

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: Theme.Spacing.tight) {
                Image(systemName: "bubble.left.and.text.bubble.right")
                    .font(.caption)
                Text(Strings.Thread.replies(thread.replies))
                    .font(.caption.weight(.semibold))
                if let latest = latestLine {
                    Text(verbatim: latest)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Image(systemName: "chevron.forward")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(accent.color)
            .padding(.horizontal, Theme.Spacing.close)
            .padding(.vertical, Theme.Spacing.tight)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }

    private var latestLine: String? {
        switch (thread.latestSender, thread.latestText) {
        case let (sender?, text?): "\(sender): \(text)"
        case let (nil, text?): text
        default: nil
        }
    }
}
