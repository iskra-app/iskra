#if os(iOS)
import SwiftUI
import IskraDesign

/// Choosing which icon the app wears on the home screen — a grid that lives in a section of
/// `AppearanceView`, not a screen of its own. It was one, behind an "Icon" row on the settings
/// root; an icon is a choice about how the app looks, and it sits with the others now.
///
/// Eight tiles, laid out like the colour swatches above it and for the same reason: what is being
/// chosen *is* a picture, so it is shown rather than named in a menu. The names are still there,
/// under each tile, because unlike a colour an icon does have a name worth reading.
///
/// There is no undo and none is needed — the icon the app ships with is the first tile, always
/// there, and going back to it is one tap.
struct HomeIconPicker: View {
    /// What is in force, drawn straight out of storage.
    ///
    /// It used to be `@State`, filled from UIKit in `onAppear`. That is the shape of the bug it
    /// caused: a pushed screen is built afresh every time it is returned to, so the ring was
    /// blank for as long as it took the fill to happen, and it stayed blank for good whenever
    /// the fill produced `spark` — which it did, because the note behind it went unwritten every
    /// time `setAlternateIconName` reported a cancellation for a change it had made. Read from
    /// `@AppStorage` there is nothing to re-fill and nothing to be late: the value the screen
    /// opens with is the value it closed with, and `HomeIcons.set` writes the same key, so a
    /// change lights the new tile without the screen being told twice.
    @AppStorage(HomeIcons.rememberedKey) private var chosen = HomeIcon.spark.rawValue

    private var icon: HomeIcon { HomeIcon(rawValue: chosen) ?? .spark }

    /// What went wrong, when the system refused the change.
    @State private var failed = false

    @Environment(\.accent) private var accent

    /// Sized by the tile, like every other grid in settings.
    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: Theme.Size.appIconTile), spacing: Theme.Spacing.roomy)]
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: Theme.Spacing.roomy) {
            ForEach(HomeIcon.allCases) { candidate in
                tile(candidate)
            }
        }
        .padding(.vertical, Theme.Spacing.close)
        // Only for the case the note cannot cover — a reinstall, or an icon set by a build that
        // kept no note. It writes the same key the ring reads, so there is nothing to assign.
        .onAppear { HomeIcons.reconcile() }
        .alert(Text(Strings.HomeIcon.failed), isPresented: $failed) {
            Button(String(app: Strings.HomeIcon.failedOK), role: .cancel) {}
        }
    }

    private func tile(_ candidate: HomeIcon) -> some View {
        VStack(spacing: Theme.Spacing.tight) {
            Button {
                choose(candidate)
            } label: {
                artwork(candidate)
            }
            .buttonStyle(.plain)

            // One line, whatever the name. «Рио-де-Жанейро» used to wrap onto a second one and push
            // its tile out of line with the rest of the row; it shrinks to the column instead.
            Text(Strings.HomeIcon.name(candidate))
                .font(.caption)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .foregroundStyle(candidate == icon ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(candidate == icon ? [.isButton, .isSelected] : .isButton)
    }

    /// The icon as it will be on the home screen — the picture of it, not an impression.
    ///
    /// It used to be drawn, because a compiled Icon Composer document cannot be got back out of
    /// the bundle as a picture. It still cannot: what changed is that the icons stopped being
    /// one shape on eight grounds, so the set now ships its own exports and the tile shows one —
    /// see `HomeIcon.preview`, which is also where the second copy of the artwork is argued for.
    ///
    /// The export carries the rounded corner and is transparent outside it, so there is no mask
    /// and nothing behind it. The gloss, the shadow under the glyph and the tint the system can
    /// put over the whole thing all survive, which the drawn tile never had.
    private func artwork(_ candidate: HomeIcon) -> some View {
        let side = Theme.Size.appIconTile
        let radius = Theme.Radius.appIcon(side: side)
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        // The ring stands `tight` off the tile, so its corner is the tile's plus that gap. With
        // the tile's own radius it was a tighter curve than the corner inside it, and the gap
        // between them swelled at every corner.
        let ring = RoundedRectangle(cornerRadius: radius + Theme.Spacing.tight, style: .continuous)

        return Group {
            if let preview = candidate.preview {
                preview
                    .resizable()
                    .interpolation(.high)
            } else {
                // Not nothing. A preview that failed to load would otherwise be a gap in the
                // grid with a name under it, which reads as a bug in the icon rather than in
                // the app — see `HomeIcon.preview`, and `--probe-icons`, which names the file.
                shape.fill(.quaternary)
            }
        }
        .frame(width: side, height: side)
            .overlay {
                // A ring on the chosen one, set off the tile so it reads as a ring rather than
                // as an edge the artwork happens to have — the same device the colour swatches
                // use, and for the same reason: the black-and-white icon on a white sheet would
                // otherwise be an invisible choice.
                ring
                    .strokeBorder(candidate == icon ? AnyShapeStyle(accent.color) : AnyShapeStyle(.quaternary),
                                  lineWidth: candidate == icon ? Theme.Border.thick : Theme.Border.hairline)
                    .padding(-Theme.Spacing.tight)
            }
            .contentShape(.rect)
    }

    private func choose(_ candidate: HomeIcon) {
        guard candidate != icon else { return }

        Task {
            do {
                // The ring follows the note this writes, so there is nothing to set here.
                try await HomeIcons.set(candidate)
            } catch {
                // A refusal leaves the note alone, so the ring is already back on whatever is
                // really in force. A tile that stays lit after the system refused it is the
                // screen telling a lie about the home screen, which the person can go and check
                // in two seconds.
                HomeIcons.reconcile()
                failed = true
            }
        }
    }
}
#endif
