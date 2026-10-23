import SwiftUI
import IskraDesign

/// The eight colours the app can be painted in, as a grid of circles you pick one from.
///
/// It lives here rather than inside `AppearanceView` because it is now asked twice: once on the
/// appearance screen, and once on the first run, where the same question is the whole of a screen
/// (`AppearanceStep`). Two copies of a grid of colours would be two copies of the ring, the tick
/// and the accessibility label that make the chosen one *look* chosen — and the copy that was not
/// touched is the one that drifts.
///
/// A grid rather than a `Picker`: a picker names its options in words and hides all but the chosen
/// one behind a menu, and the one thing a colour cannot usefully be described as is its name. The
/// names are still on every swatch, where only VoiceOver reads them.
struct AccentSwatches: View {
    @Binding var accent: AccentTheme

    /// Sized by the swatch, not by a column count. Eight circles are a comfortable row on a Mac
    /// and a wrapped pair of rows on a phone, and neither has to be spelled out.
    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: Theme.Size.accentSwatch), spacing: Theme.Spacing.roomy)]
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: Theme.Spacing.roomy) {
            ForEach(AccentTheme.allCases) { theme in
                swatch(theme)
            }
        }
    }

    /// The tick, scaled with the circle it sits in.
    #if os(macOS)
    private static let tick: Font = .caption2
    #else
    private static let tick: Font = .body
    #endif

    private func swatch(_ theme: AccentTheme) -> some View {
        Button {
            withAnimation(.smooth(duration: Theme.Timing.reaction)) { accent = theme }
        } label: {
            Circle()
                .fill(theme.color)
                .frame(width: Theme.Size.accentSwatch, height: Theme.Size.accentSwatch)
                .overlay {
                    // The tick is drawn in whatever stays legible on the colour it lands on
                    // — which is the same question the app answers for the text in a bubble,
                    // and is answered in the same place. On the mono theme that is the one
                    // thing that keeps it visible at all.
                    if theme == accent {
                        Image(systemName: "checkmark")
                            .font(Self.tick.weight(.bold))
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
