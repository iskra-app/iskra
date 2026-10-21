import SwiftUI
import PhotosUI
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

    /// A checkbox view of the same storage: the plain column is either on or it is not.
    private var isCompact: Binding<Bool> {
        Binding(
            get: { layout == .compact },
            set: { newValue in layout = newValue ? .compact : .bubbles }
        )
    }

    /// What the conversations are standing on, and how far down it is taken — see `Wallpaper`.
    @AppStorage(Wallpaper.storageKey) private var wallpaper: Wallpaper = .default
    @AppStorage(Wallpaper.dimmingKey) private var dimming: Double = Wallpaper.defaultDimming

    /// The photograph being picked, while it is being picked.
    @State private var pickedWallpaper: PhotosPickerItem?

    /// Whether the photo library is up.
    @State private var isChoosingWallpaper = false

    /// Which way round the tick on a chosen wallpaper goes on the colourless theme.
    @Environment(\.colorScheme) private var scheme

    /// The user's own picture, held where every room can reach it.
    private let wallpapers = WallpaperStore.shared

    /// Whether the colour is let out of the messages and onto the chrome as well. Written here and
    /// read at the root — see `AccentTheme.tintsInterfaceKey`.
    @AppStorage(AccentTheme.tintsInterfaceKey) private var tintsInterface = false

    var body: some View {
        Form {
            Section {
                conversation
            }

            Section {
                Toggle(isOn: isCompact.animation(.smooth(duration: Theme.Timing.reaction))) {
                    Text(Strings.Appearance.compact)
                }
                // The root tint is `.primary` when interface tinting is off, so a switch would
                // turn white-on-white. The accent is the colour the user came here to pick, and
                // it should colour the switch itself regardless of whether it washes the rest —
                // and on the colourless theme it is a legible grey rather than the foreground
                // colour. See `AccentControl`, which is now every switch in the app.
                .accentControl()
            }

            Section {
                Picker(selection: $appearance) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(Strings.Appearance.mode(mode)).tag(mode)
                    }
                } label: {
                    EmptyView()
                }
                .pickerStyle(.segmented)
            } header: {
                Text(Strings.Appearance.theme)
            }

            Section {
                // The same grid the first run asks the same question with — see `AccentSwatches`.
                AccentSwatches(accent: $accent)
                    .padding(.vertical, Theme.Spacing.close)

                Toggle(isOn: $tintsInterface.animation(.smooth(duration: Theme.Timing.reaction))) {
                    Text(Strings.Appearance.tintInterface)
                }
                .accentControl()
            } header: {
                Text(Strings.Appearance.accent)
            }

            // iPhone and iPad only, and not drawn at all where the device forbids it.
            // `setAlternateIconName` is UIKit's and AppKit has no equivalent — see `HomeIcon`.
            #if os(iOS)
            if HomeIcons.areSupported {
                Section {
                    HomeIconPicker()
                } header: {
                    Text(Strings.Settings.appIcon)
                }
            }
            #endif

            Section {
                wallpaperRow

                if wallpaper.isSet {
                    dimmer
                }
            } header: {
                Text(Strings.Appearance.wallpaper)
            }
        }
        .formStyle(.groupedRows)
        .photosPicker(isPresented: $isChoosingWallpaper,
                      selection: $pickedWallpaper,
                      matching: .images)
        .onChange(of: pickedWallpaper) { _, item in
            guard let item else { return }
            Task { await setWallpaper(item) }
            // Cleared so that picking the same photograph twice in a row is two choices and not
            // one — `onChange` fires on a change, and the second pick is not one.
            pickedWallpaper = nil
        }
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
        .padding(Theme.Spacing.normal)
        // Standing on the wallpaper, because that is where a conversation stands.
        //
        // The preview exists to answer "what will this look like to live in", and until now it
        // answered it on the app's own page while the rooms it stands for were on a photograph.
        // That is not a small difference: over a wallpaper a bubble stops being a percentage of
        // the foreground colour and takes an opaque fill instead — see `EnvironmentValues
        // .hasWallpaper` — so the accent the swatches above are choosing is a *different colour*
        // in the two cases, and the one being shown was the one the user would not get.
        //
        // It also makes the row below it worth looking at: the dimmer is a slider about
        // legibility, and legibility is a question about words on a picture, which is the thing
        // this card now is.
        .background {
            // Sized and clipped here, not trusted to fill: the backdrop ignores the safe area,
            // which is what a wallpaper wants and exactly what a card inside a form must not do.
            // The same care the tiles take — see `tile(_:)`.
            WallpaperBackdrop(wallpaper: wallpaper, photo: wallpapers.photo, dimming: dimming)
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.picture, style: .continuous))
        // Told, so the bubbles inside it draw the way they will in a room. The whole point of the
        // card is that it does not lie about this.
        .environment(\.hasWallpaper, wallpaper.isSet)
        .environment(\.wallpaperIsDark, wallpapers.isDark(wallpaper, dimming: dimming))
        // The picture is read off the disk once per launch, and this screen can be the first thing
        // to want it — somebody who has a wallpaper and opens Appearance before opening a room.
        .task { await wallpapers.load() }
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

    /// The wallpapers, in a row you scroll: nothing, six gradients, and your own photograph.
    ///
    /// A row rather than the grid the colours use, and the difference is what is being chosen. A
    /// colour is a dot, and eight dots wrap comfortably into two lines; a wallpaper is a *picture*,
    /// and a picture shown small enough to fit eight of them across a phone is a picture nobody can
    /// judge. So these are tall tiles, the shape of the screen they will fill, and the row scrolls.
    private var wallpaperRow: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Theme.Spacing.normal) {
                ForEach(Wallpaper.allCases) { choice in
                    wallpaperTile(choice)
                }
            }
            .padding(.vertical, Theme.Spacing.close)
        }
        .scrollIndicators(.hidden)
        // The row runs the full width of the sheet rather than sitting inside the form's own
        // margins, so that a tile scrolled to the edge slides under it instead of stopping short.
        .listRowInsets(EdgeInsets(top: 0, leading: Theme.Spacing.normal, bottom: 0, trailing: 0))
    }

    private func wallpaperTile(_ choice: Wallpaper) -> some View {
        Button {
            // Choosing your own picture is choosing a *file*, so the library comes up and the
            // setting changes only once there is something to set it to. Unless there already is
            // one, in which case this is simply going back to it.
            if choice == .photo, wallpapers.photo == nil {
                isChoosingWallpaper = true
                return
            }

            withAnimation(.smooth(duration: Theme.Timing.reaction)) { wallpaper = choice }
        } label: {
            tile(choice)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(Strings.Appearance.wallpaperName(choice)))
        .accessibilityAddTraits(choice == wallpaper ? [.isButton, .isSelected] : .isButton)
    }

    /// One tile: the wallpaper as it will be, with the dimming already on it, so that the slider
    /// below has something to be about.
    private func tile(_ choice: Wallpaper) -> some View {
        RoundedRectangle(cornerRadius: Theme.Radius.picture, style: .continuous)
            .fill(.quaternary)
            .frame(width: Theme.Size.wallpaperTile.width, height: Theme.Size.wallpaperTile.height)
            .overlay {
                // Clipped and framed here rather than trusted to fill the tile: the backdrop
                // ignores the safe area, which is exactly what a wallpaper wants and exactly what a
                // thumbnail of one must not do.
                WallpaperBackdrop(wallpaper: choice, photo: wallpapers.photo, dimming: dimming)
                    .frame(width: Theme.Size.wallpaperTile.width,
                           height: Theme.Size.wallpaperTile.height)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.picture, style: .continuous))
            }
            .overlay {
                // The tile with nothing to show says so, and the photograph nobody has chosen yet
                // says what pressing it will do.
                if choice == .none {
                    Image(systemName: "nosign")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                } else if choice == .photo, wallpapers.photo == nil {
                    Image(systemName: "photo.badge.plus")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if choice == wallpaper {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.body.weight(.bold))
                        .foregroundStyle(.white, accent.control(in: scheme))
                        .padding(Theme.Spacing.close)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.picture, style: .continuous)
                    .strokeBorder(choice == wallpaper ? AnyShapeStyle(.primary) : AnyShapeStyle(.quaternary),
                                  lineWidth: Theme.Border.hairline)
            }
            .contentShape(.rect)
    }

    /// How far down the wallpaper is taken.
    ///
    /// Shown only when there is a wallpaper, because a dimmer over nothing dims nothing — and the
    /// tiles above it darken as it moves, so the setting is read off the pictures rather than off
    /// the slider.
    private var dimmer: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
            HStack {
                Text(Strings.Appearance.wallpaperDimming)
                Spacer()
                Text(dimming.formatted(.percent.precision(.fractionLength(0))))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Slider(value: $dimming, in: 0...Wallpaper.maximumDimming)
                .accentControl()

            // Changing one's mind about the photograph, which is the only wallpaper that can be
            // changed as well as chosen.
            if wallpaper == .photo {
                Button(String(app: Strings.Appearance.wallpaperChoose)) {
                    isChoosingWallpaper = true
                }
                .font(.callout)
                .padding(.top, Theme.Spacing.tight)
            }
        }
    }

    private func setWallpaper(_ item: PhotosPickerItem) async {
        guard let data = await imageData(from: item) else { return }
        wallpapers.store(data)
        withAnimation(.smooth(duration: Theme.Timing.reaction)) { wallpaper = .photo }
    }
}
