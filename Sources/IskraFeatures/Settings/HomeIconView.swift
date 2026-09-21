#if os(iOS)
import SwiftUI
import IskraDesign

/// Choosing which icon the app wears on the home screen.
///
/// Six tiles and nothing else, laid out like the colour swatches on the appearance screen and
/// for the same reason: what is being chosen *is* a picture, so it is shown rather than named in
/// a menu. The names are still there, under each tile, because unlike a colour an icon does have
/// a name worth reading.
///
/// Two things here are the system's and not ours, and both are worth knowing before the first
/// tap. Changing the icon shows an alert saying it has changed — iOS's own, unsuppressable — so
/// the footer says it is coming, and an alert that was expected reads as confirmation rather
/// than as something having gone wrong. And the change is not instant everywhere: the home
/// screen updates, while the icon in the app switcher and in Spotlight can take a moment to
/// catch up.
///
/// There is no undo and none is needed — the icon the app ships with is the first tile, always
/// there, and going back to it is one tap.
struct HomeIconView: View {
    /// What is in force, read from UIKit rather than kept in `@AppStorage`.
    ///
    /// UIKit *is* the storage here: the choice survives reinstall-less updates because the
    /// system remembers it, and a copy of ours could only ever disagree with it. It is read once
    /// when the screen appears and then kept in step by hand, because the only thing that can
    /// change it is this screen.
    @State private var icon = HomeIcon.spark

    /// What went wrong, when the system refused the change.
    @State private var failed = false

    @Environment(\.accent) private var accent

    /// Sized by the tile, like every other grid in settings.
    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: Theme.Size.appIconTile), spacing: Theme.Spacing.roomy)]
    }

    var body: some View {
        Form {
            Section {
                LazyVGrid(columns: columns, spacing: Theme.Spacing.roomy) {
                    ForEach(HomeIcon.allCases) { candidate in
                        tile(candidate)
                    }
                }
                .padding(.vertical, Theme.Spacing.close)
            } footer: {
                Text(Strings.HomeIcon.help)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(Text(Strings.Settings.appIcon))
        .toolbarTitleDisplayMode(.inline)
        .onAppear { icon = HomeIcons.current }
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

            Text(Strings.HomeIcon.name(candidate))
                .font(.caption)
                .foregroundStyle(candidate == icon ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(candidate == icon ? [.isButton, .isSelected] : .isButton)
    }

    /// The icon as it will be on the home screen, drawn rather than loaded.
    ///
    /// Drawn because it has to be: an Icon Composer document is compiled into a form only the
    /// home screen can read, and the alternates cannot be got back out of the bundle as pictures
    /// at all — see `SparkShape`, which is also where the spark itself comes from. The ground and
    /// the glyph's colour are the two numbers each `.icon` file names, and the shape is the very
    /// same vector, so this is the icon rather than an impression of it.
    ///
    /// What it does not reproduce is Icon Composer's own gloss — the layered gradient, the shadow
    /// under the glyph, the tint the system can put over the whole thing. A picker's job is to
    /// let somebody tell six icons apart, and colour and shape do that.
    private func artwork(_ candidate: HomeIcon) -> some View {
        let side = Theme.Size.appIconTile
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.appIcon(side: side), style: .continuous)

        return shape
            .fill(candidate.ground.gradient)
            .frame(width: side, height: side)
            .overlay {
                SparkShape()
                    .fill(candidate.spark)
                    // The glyph fills the icon almost to its edges in the real thing — the
                    // document scales it to 1.12 — and a spark drawn politely small in the middle
                    // of a tile is a different picture.
                    .padding(side * 0.12)
            }
            .overlay {
                // A ring on the chosen one, set off the tile so it reads as a ring rather than
                // as an edge the artwork happens to have — the same device the colour swatches
                // use, and for the same reason: the paper icon on a white sheet would otherwise
                // be an invisible choice.
                shape
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
                try await HomeIcons.set(candidate)
                icon = HomeIcons.current
            } catch {
                // Put back what is actually in force rather than what was tapped. A tile that
                // stays lit after the system refused it is the screen telling a lie about the
                // home screen, which the person can go and check in two seconds.
                icon = HomeIcons.current
                failed = true
            }
        }
    }
}
#endif
