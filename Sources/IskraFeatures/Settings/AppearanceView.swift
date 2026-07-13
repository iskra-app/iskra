import SwiftUI
import IskraDesign

/// Choosing the colour the app is painted in.
///
/// Eight swatches and nothing else. The choice is written straight to `@AppStorage`, which
/// the root of the app reads — so there is no "apply" and no "done": the colour under your
/// finger is already the colour of the screen you are standing on, and the checkmark that
/// lands on it is drawn in it.
///
/// A grid rather than a `Picker`. A picker names its options in words and hides all but the
/// chosen one behind a menu, and the one thing a colour cannot usefully be described as is
/// its name — you pick a colour by looking at it. The names are still there, on every
/// swatch, where only VoiceOver reads them.
struct AppearanceView: View {
    @AppStorage(AccentTheme.storageKey) private var accent: AccentTheme = .default

    /// Sized by the swatch, not by a column count. Eight circles are a comfortable row on a
    /// Mac and a wrapped pair of rows on a phone, and neither has to be spelled out.
    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: Theme.Size.swatch), spacing: Theme.Spacing.roomy)]
    }

    var body: some View {
        Form {
            Section {
                LazyVGrid(columns: columns, spacing: Theme.Spacing.roomy) {
                    ForEach(AccentTheme.allCases) { theme in
                        swatch(theme)
                    }
                }
                .padding(.vertical, Theme.Spacing.close)
            } header: {
                Text(Strings.Appearance.accent)
            } footer: {
                Text(Strings.Appearance.accentHelp)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(Text(Strings.Settings.appearance))
        .toolbarTitleDisplayMode(.inline)
    }

    private func swatch(_ theme: AccentTheme) -> some View {
        Button {
            withAnimation(.smooth(duration: Theme.Timing.reaction)) { accent = theme }
        } label: {
            Circle()
                .fill(theme.color)
                .frame(width: Theme.Size.swatch, height: Theme.Size.swatch)
                .overlay {
                    // The tick is drawn in whatever stays legible on the colour it lands on
                    // — which is the same question the app answers for the text in a bubble,
                    // and is answered in the same place. On the mono theme that is the one
                    // thing that keeps it visible at all.
                    if theme == accent {
                        Image(systemName: "checkmark")
                            .font(.body.weight(.bold))
                            .foregroundStyle(theme.foreground)
                    }
                }
                // A ring around the chosen one, set off the swatch so it reads as a ring and
                // not as a border the colour happens to have. Without it the mono swatch —
                // white on a white sheet in the light — would be an invisible choice.
                .overlay {
                    Circle()
                        .strokeBorder(theme == accent ? AnyShapeStyle(.primary) : AnyShapeStyle(.quaternary),
                                      lineWidth: Theme.Border.hairline)
                        .padding(-Theme.Spacing.tight)
                }
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(Strings.Appearance.color(theme)))
        .accessibilityAddTraits(theme == accent ? [.isButton, .isSelected] : .isButton)
    }
}
