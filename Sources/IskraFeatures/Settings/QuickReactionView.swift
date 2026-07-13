import SwiftUI
import IskraDesign

/// Choosing what a double tap on a message leaves behind.
///
/// Six emoji, laid out like the colour swatches on the appearance screen and for the same
/// reason: the thing being chosen *is* what it looks like, so it is shown rather than named
/// in a menu. The choice is written straight to `@AppStorage`, so there is no "done" — the
/// next double tap in any conversation already sends the new one.
struct QuickReactionView: View {
    @AppStorage(QuickReaction.storageKey) private var reaction: QuickReaction = .default

    @Environment(\.accent) private var accent

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: Theme.Size.swatch), spacing: Theme.Spacing.roomy)]
    }

    var body: some View {
        Form {
            Section {
                LazyVGrid(columns: columns, spacing: Theme.Spacing.roomy) {
                    ForEach(QuickReaction.allCases) { candidate in
                        choice(candidate)
                    }
                }
                .padding(.vertical, Theme.Spacing.close)
            } header: {
                Text(Strings.Reactions.quick)
            } footer: {
                Text(Strings.Reactions.quickHelp)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(Text(Strings.Settings.reactions))
        .toolbarTitleDisplayMode(.inline)
    }

    private func choice(_ candidate: QuickReaction) -> some View {
        Button {
            withAnimation(.smooth(duration: Theme.Timing.reaction)) { reaction = candidate }
        } label: {
            Text(candidate.key)
                .font(.title2)
                .frame(width: Theme.Size.swatch, height: Theme.Size.swatch)
                // The chosen one sits in a disc of the app's colour. The unchosen ones sit on
                // nothing at all — an emoji is legible against the sheet it is on, and a row of
                // six grey circles would read as six buttons that are all switched off.
                .background {
                    if candidate == reaction {
                        Circle().fill(accent.color.opacity(0.18))
                        Circle().strokeBorder(accent.color, lineWidth: Theme.Border.hairline)
                    }
                }
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        // VoiceOver reads an emoji by its own name, which is better than anything we would
        // write for it; what it cannot say is which one is currently in force.
        .accessibilityAddTraits(candidate == reaction ? [.isButton, .isSelected] : .isButton)
    }
}
