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
    @AppStorage(AppearanceMode.storageKey) private var appearance: AppearanceMode = .default

    /// Bubbles or the plain column — see `MessageLayout`. Written here and read where the
    /// conversation is drawn, the same way the two above travel.
    @AppStorage(MessageLayout.storageKey) private var layout: MessageLayout = .default

    /// Whether the colour is let out of the messages and onto the chrome as well. Written here and
    /// read at the root — see `AccentTheme.tintsInterfaceKey`.
    @AppStorage(AccentTheme.tintsInterfaceKey) private var tintsInterface = false

    /// Sized by the swatch, not by a column count. Eight circles are a comfortable row on a
    /// Mac and a wrapped pair of rows on a phone, and neither has to be spelled out.
    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: Theme.Size.swatch), spacing: Theme.Spacing.roomy)]
    }

    var body: some View {
        Form {
            Section {
                conversation
            }

            // Directly under the preview, because it is a question *about* the preview — the same
            // placement, and the same reasoning, as the tint switch further down. Flipping it
            // redraws the three lines above into the shape it names, which is the whole argument
            // the footer would otherwise have to make in words.
            Section {
                Picker(selection: $layout.animation(.smooth(duration: Theme.Timing.reaction))) {
                    ForEach(MessageLayout.allCases) { layout in
                        Text(Strings.Appearance.layout(layout)).tag(layout)
                    }
                } label: {
                    Text(Strings.Appearance.layout)
                }
                .pickerStyle(.segmented)
            } footer: {
                Text(Strings.Appearance.layoutHelp)
            }

            // A segmented picker and not a grid: these three have names and *only* names — there
            // is nothing to look at, and "System" cannot be drawn as a swatch. The preview above
            // is the one thing that shows what was chosen, and it repaints with the screen.
            Section {
                Picker(selection: $appearance) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(Strings.Appearance.mode(mode)).tag(mode)
                    }
                } label: {
                    Text(Strings.Appearance.theme)
                }
                .pickerStyle(.segmented)
            } footer: {
                Text(Strings.Appearance.themeHelp)
            }

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
                Text(Strings.Appearance.accentHelp(layout))
            }

            // Below the colours, because it is a question about the colour above it and makes no
            // sense before one has been picked. Its own section, so that the footer explaining it
            // is not a second footer under the swatches.
            //
            // Flipping it bathes the screen it is standing on — this very Form, its background, the
            // words on it — in the accent, which is the demonstration, and the reason this does not
            // need a preview of its own the way the accent does.
            Section {
                Toggle(isOn: $tintsInterface.animation(.smooth(duration: Theme.Timing.reaction))) {
                    Text(Strings.Appearance.tintInterface)
                }
                // The mono theme's colour *is* the foreground colour, so a wash of it would grey the
                // app down rather than tint it: the switch would move and the app would only dim. It
                // says so instead of pretending.
                .disabled(accent == .mono)
            } footer: {
                Text(accent == .mono ? Strings.Appearance.tintInterfaceMono
                                     : Strings.Appearance.tintInterfaceHelp(layout))
            }
        }
        .formStyle(.grouped)
        .navigationTitle(Text(Strings.Settings.appearance))
        .toolbarTitleDisplayMode(.inline)
    }

    /// Four lines of a conversation that never happened, so the two choices above can be made by
    /// looking at the thing they are for.
    ///
    /// The swatches say what the colour *is*; they cannot say what it will look like as a
    /// message. Those are different questions, and the second one is the one being asked: an
    /// accent is not a circle on a settings screen, it is the fill behind everything you will
    /// ever say. A yellow that is cheerful as a dot can be unreadable as a bubble, and until now
    /// the only way to find that out was to leave this screen, open a room, and say something.
    ///
    /// It repaints as either picker is pressed, and it costs nothing to make it: `messageBubble`
    /// reads the accent from the environment, the environment reads it from the same
    /// `@AppStorage` this screen writes, so the lines below are already listening.
    ///
    /// It has to follow the layout as well as the colour, and that is not a flourish. Under the
    /// compact column the accent never touches a message at all — so a preview that went on
    /// drawing bubbles would be showing the reader a thing their app will never do, on the very
    /// screen where they are choosing it. What it shows there instead is the truth, and it is
    /// worth seeing before choosing: your own line no longer stands out from anybody else's.
    private var conversation: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.close) {
            switch layout {
            case .bubbles:
                // The second line is the user's own, and it is the only one that matters here —
                // an incoming bubble is grey in every theme. The others are there for contrast:
                // a colour is chosen against what sits next to it, and what sits next to it is
                // grey.
                bubble(Strings.Appearance.previewAsk, isOwn: false)
                bubble(Strings.Appearance.previewAnswer, isOwn: true)
                bubble(Strings.Appearance.previewReply, isOwn: false)
                bubble(Strings.Appearance.previewFollowUp, isOwn: false)

            case .compact:
                line(Strings.Appearance.previewAsk, from: Strings.Appearance.previewSender)
                line(Strings.Appearance.previewAnswer, from: Strings.Message.Spoken.you)
                line(Strings.Appearance.previewReply, from: Strings.Appearance.previewSender)
                // No name: the fourth line is the second from the same person, and a run carries
                // one header. This is the whole of what the layout does, so the preview has to
                // have a run in it to show.
                line(Strings.Appearance.previewFollowUp, from: nil)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, Theme.Spacing.close)
        // One thing, read as one thing. Four bubbles apiece would have VoiceOver walk somebody
        // through a fake conversation on the way to the colours they came for.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(Strings.Appearance.previewLabel))
    }

    private func bubble(_ line: LocalizedStringResource, isOwn: Bool) -> some View {
        Text(line)
            .font(.callout)
            .messageBubble(isOwn ? .own : .incoming)
            .frame(maxWidth: .infinity, alignment: isOwn ? .trailing : .leading)
    }

    /// One line of the compact preview: a name over it, or nothing where the line before it was
    /// from the same person.
    ///
    /// A sketch rather than a `CompactMessageRow`. The real row wants a `Message`, nine
    /// callbacks, a measured timeline width and a media loader — and it would bring its context
    /// menu with it, so a long press on a conversation that never happened would offer to delete
    /// a message that does not exist. What is being shown here is the shape, and the shape is
    /// four lines and two names.
    @ViewBuilder
    private func line(_ text: LocalizedStringResource, from sender: LocalizedStringResource?) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
            if let sender {
                Text(sender)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            Text(text)
                .font(.callout)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
