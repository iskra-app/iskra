import SwiftUI
import IskraCore
import IskraDesign

/// What a room turns out to be made of, once you stop reading it as a conversation: the people in
/// it, the pictures, the voice notes, the round videos, the files, and the addresses somebody
/// pasted three months ago and everybody has been scrolling for since.
///
/// Six ways of looking at the same history, and the info screen shows one at a time. They are tabs
/// rather than six screens behind six rows because finding a file is *browsing* — you go in not
/// quite knowing which of these it was, and a tab strip lets you try the next guess without
/// walking back out of a screen first.
enum RoomContentTab: Hashable, CaseIterable, Identifiable {
    case members
    case media
    case voice
    case videoNotes
    case files
    case links

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .members: Strings.Room.Tabs.members
        case .media: Strings.Room.Tabs.media
        case .voice: Strings.Room.Tabs.voice
        case .videoNotes: Strings.Room.Tabs.videoNotes
        case .files: Strings.Room.Tabs.files
        case .links: Strings.Room.Tabs.links
        }
    }
}

/// The switch above the room's contents: the six words, in a row you can push sideways.
///
/// It has been three things now, and each change was a lesson worth keeping.
///
/// It was a strip of hand-drawn capsules on a sheet of glass inside a `Form` section, which is two
/// surfaces and a control — the grouped card drew a plate, the glass drew a second one on top of
/// it, and the pills drew a third. Then it was the system's segmented control, standing straight on
/// the page, which fixed the floors and cost the words: a segmented control divides its width
/// evenly between its segments, and six Russian words do not fit in six sixths of a phone, so it
/// was six symbols instead. A waveform and a circled camera are a guess the reader has to make,
/// «Голосовые» and «Кружки» are not, and asking somebody to decode a row of glyphs to find a file
/// is the wrong trade on a screen whose whole job is browsing.
///
/// So: the words, in a scrolling row of capsules. Scrolling is what buys them — a strip is allowed
/// to be wider than the screen, which a segmented control is not, so nothing has to be shortened to
/// «Виде…» and nothing has to be drawn as a picture of itself. Six is few enough that most of them
/// are visible at once and the rest are one push away, and the selected one is scrolled into view
/// whenever it changes, so pressing the strip never leaves the answer off the edge.
///
/// The capsules are opaque fills, not glass: this is content, on a page, and Liquid Glass belongs
/// to the navigation layer (`IskraDesign/Glass.swift`). The chosen one is the accent with the
/// accent's own readable foreground on it — the `AccentTheme` pair, same as every other place in
/// the app where something is filled with the accent and written on.
struct RoomContentPicker: View {
    let tabs: [RoomContentTab]
    @Binding var selection: RoomContentTab

    var body: some View {
        ScrollViewReader { strip in
            ScrollView(.horizontal) {
                HStack(spacing: Theme.Spacing.close) {
                    ForEach(tabs) { tab in
                        Capsule(tab: tab, isChosen: tab == selection) { choose(tab) }
                            .id(tab)
                    }
                }
                // The strip's own margins, because the row it lives in has none — it is laid on the
                // page rather than in a card, so the inset that lines it up with the cards above and
                // below is here. On the scroll view's *content*, so a capsule at either end scrolls
                // past the margin instead of being clipped by it.
                .padding(.horizontal, Theme.Spacing.roomy)
                .padding(.vertical, Theme.Spacing.close)
            }
            .scrollIndicators(.hidden)
            // One container with six things in it, rather than six unrelated buttons floating
            // above a list. "What's in here" is the introduction VoiceOver gives before reading
            // them out, and it is the only place that name is ever spoken.
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text(Strings.Room.Tabs.label))
            // A tab can also be chosen by something other than a press — a personal chat opens on
            // whatever the first available tab is, and a room that loses its last file loses the
            // segment somebody was standing on. Following the selection here rather than in
            // `choose` covers both.
            .onChange(of: selection) { _, tab in
                withAnimation(.easeInOut(duration: Theme.Timing.chrome)) {
                    strip.scrollTo(tab, anchor: .center)
                }
            }
        }
    }

    /// One word, and whether it is the one you are looking at.
    ///
    /// Its own view rather than three modifiers in the loop above, because the fill and the words
    /// on it are each a choice between two styles and the type-checker cannot see through a stack
    /// of those inside a `ForEach` inside a `ScrollView` — it gives up and says so. Pulled out, the
    /// choice is made once in a property with a name.
    private struct Capsule: View {
        let tab: RoomContentTab
        let isChosen: Bool
        let choose: () -> Void

        @Environment(\.accent) private var accent

        var body: some View {
            Button(action: choose) {
                Text(tab.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .padding(.horizontal, Theme.Spacing.normal)
                    .padding(.vertical, Theme.Spacing.close)
                    .foregroundStyle(words)
                    .background(fill, in: .capsule)
                    .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isChosen ? [.isButton, .isSelected] : .isButton)
        }

        /// The accent under the chosen one, and the faintest possible plate under the rest — enough
        /// to read as a row of pressable things, not enough to compete with the one that is lit.
        private var fill: AnyShapeStyle {
            isChosen ? AnyShapeStyle(accent.color) : AnyShapeStyle(Color.primary.opacity(0.08))
        }

        /// Whatever stays readable on that fill — `AccentTheme.foreground`, which is white for six
        /// of the seven colours, black on yellow, and the background colour on mono. The plain one
        /// rather than `foreground(in:)`: that variant exists for labels drawn on *glass*, where
        /// "the background" resolves to the glass itself. This capsule is an opaque fill on a page,
        /// which is the case the contextual style was made for.
        private var words: AnyShapeStyle {
            isChosen ? accent.foreground : AnyShapeStyle(.secondary)
        }
    }

    /// The change to the list underneath, animated.
    ///
    /// The capsule swaps its own fill whatever this does; what needs saying is that the *list*
    /// should cross-fade rather than jump — six different kinds of content in one place, swapped
    /// with no transition, reads as the screen being rebuilt under the reader.
    private func choose(_ tab: RoomContentTab) {
        guard tab != selection else { return }
        withAnimation(.easeInOut(duration: Theme.Timing.chrome)) { selection = tab }
    }
}

// MARK: - What each tab is made of

/// The pictures and the videos, as a grid — the arrangement the eye can actually search, which a
/// list of filenames is not.
struct RoomMediaGrid: View {
    let items: [MediaItem]
    /// Opening one opens all of them, swipeable: the index is which one was pressed.
    @State private var openedAt: Int?

    private let columns = [GridItem(.adaptive(minimum: 96), spacing: Theme.Spacing.tight)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: Theme.Spacing.tight) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                Button {
                    openedAt = index
                } label: {
                    // The square is the *container*, and the picture is a passenger inside it.
                    //
                    // Asking the thumbnail itself for `aspectRatio(1, .fill)` is what broke the
                    // grid: `.fill` on the image means "cover the space, overflowing if you must",
                    // and an overflowing view still reports its overflowed size to the layout. A
                    // panorama therefore made its own cell wide, the row it was in grew with it,
                    // and the columns stopped lining up — the clip shape hid the spill without
                    // changing the arithmetic, so the mess was invisible in the cell and obvious
                    // in the grid.
                    //
                    // `Color.clear` with a 1:1 ratio has no opinion of its own and cannot be
                    // pushed around; the overlay is laid out to the square and clipped to it, so
                    // a photograph of any shape produces exactly the same tile.
                    Color.clear
                        .aspectRatio(1, contentMode: .fit)
                        .overlay {
                            MediaThumbnail(attachment: item.attachment)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                        .overlay(alignment: .bottomTrailing) {
                            if item.isVideo {
                                Image(systemName: "play.circle.fill")
                                    .foregroundStyle(.white)
                                    .padding(Theme.Spacing.tight)
                                    .shadow(radius: 2)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .sheet(item: Binding(get: { openedAt.map { OpenedIndex(value: $0) } },
                             set: { openedAt = $0?.value })) { opened in
            MediaPager(items: items, startIndex: opened.value)
        }
    }
}

/// The voice notes, as rows that play where they are.
///
/// Pressing one does not open anything — there is nothing to look at — so it plays in place, on the
/// same `AudioPlayback` the conversation uses. That shared player is what keeps a voice note
/// started here from talking over one started in the chat behind: the speaker has one claimant.
struct RoomVoiceList: View {
    let items: [MediaItem]

    @Environment(\.mediaLoader) private var loader
    @State private var playback = AudioPlayback()

    /// Which note the player is holding. `AudioPlayback` knows whether it is playing and not what
    /// it is playing — it is handed an attachment per call — so the list keeps that half, and a
    /// press on a *different* row stops the old one before starting the new.
    @State private var playing: String?

    var body: some View {
        ForEach(items) { item in
            Button {
                Task { await press(item) }
            } label: {
                RoomContentRow(icon: icon(for: item),
                               title: Text(item.sender),
                               detail: item.attachment.duration.map {
                                   Text(Duration.seconds($0), format: .time(pattern: .minuteSecond))
                               },
                               timestamp: item.timestamp)
            }
            .buttonStyle(.plain)
        }
        // Leaving the screen stops the sound. A voice note that goes on playing out of a list the
        // user has already closed is the app talking to itself.
        .onDisappear { playback.stop() }
    }

    private func icon(for item: MediaItem) -> String {
        playing == item.id && playback.isPlaying ? "pause.circle.fill" : "play.circle.fill"
    }

    private func press(_ item: MediaItem) async {
        if playing != item.id {
            playback.stop()
            playing = item.id
        }
        await playback.toggle(item.attachment, using: loader)
    }
}

/// The round videos. A list rather than a grid, because a video note is watched rather than
/// browsed — and because the thumbnail of one is a face at arm's length, which tiles badly.
struct RoomVideoNoteList: View {
    let items: [MediaItem]

    @State private var openedAt: Int?

    var body: some View {
        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
            Button {
                openedAt = index
            } label: {
                HStack(spacing: Theme.Spacing.normal) {
                    Color.clear
                        .frame(width: Theme.Size.avatar, height: Theme.Size.avatar)
                        .overlay { MediaThumbnail(attachment: item.attachment) }
                        .clipShape(Circle())

                    RoomContentRow.Labels(title: Text(item.sender),
                                          detail: item.attachment.duration.map {
                                              Text(Duration.seconds($0), format: .time(pattern: .minuteSecond))
                                          },
                                          timestamp: item.timestamp)
                }
                .padding(.vertical, Theme.Spacing.tight)
            }
            .buttonStyle(.plain)
        }
        .sheet(item: Binding(get: { openedAt.map { OpenedIndex(value: $0) } },
                             set: { openedAt = $0?.value })) { opened in
            MediaPager(items: items, startIndex: opened.value)
        }
    }
}

/// The files, by name — the one tab where the name is the whole of what you are looking for.
struct RoomFileList: View {
    let items: [MediaItem]

    @Environment(\.mediaLoader) private var loader
    @State private var opener = FileOpener()

    var body: some View {
        ForEach(items) { item in
            Button {
                Task { await opener.open(item.attachment, using: loader) }
            } label: {
                RoomContentRow(icon: opener.failed ? "exclamationmark.triangle" : "doc",
                               title: Text(item.attachment.filename),
                               detail: Text(item.sender),
                               timestamp: item.timestamp)
            }
            .buttonStyle(.plain)
        }
        #if !os(macOS)
        // On iOS the file is previewed inside the app; on the Mac it is handed to whatever opens
        // that kind of file, so there is no sheet to present. Same arrangement as `FileBubble`.
        .sheet(isPresented: .init(get: { opener.previewing != nil },
                                  set: { if !$0 { opener.closePreview() } })) {
            if let file = opener.previewing {
                FilePreview(url: file.url)
                    .ignoresSafeArea()
            }
        }
        #endif
    }
}

/// The addresses, newest first, each with the message it came out of underneath it.
///
/// The line under a link is the sentence it was posted in, not the page's title: fetching titles
/// would mean this app quietly visiting every address anybody has ever pasted into a room, from the
/// user's IP, including the ones they never opened. What somebody said when they posted it is both
/// cheaper and more useful — "the booking is here" tells you more than "Booking.com".
struct RoomLinkList: View {
    let items: [LinkItem]

    @Environment(\.openURL) private var openURL

    var body: some View {
        ForEach(items) { item in
            Button {
                openURL(item.url)
            } label: {
                VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                    Text(item.url.absoluteString)
                        .font(.subheadline)
                        .lineLimit(2)
                        .foregroundStyle(.tint)

                    Text(item.context)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)

                    Text(RoomTimestamp.label(for: item.timestamp))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, Theme.Spacing.tight)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
    }
}

/// One row in the three list-shaped tabs: an icon, what it is, who sent it, and when.
struct RoomContentRow: View {
    let icon: String
    let title: Text
    var detail: Text?
    let timestamp: Date

    var body: some View {
        HStack(spacing: Theme.Spacing.normal) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: Theme.Spacing.generous)

            Labels(title: title, detail: detail, timestamp: timestamp)
        }
        .padding(.vertical, Theme.Spacing.tight)
        .contentShape(.rect)
    }

    /// The words half of the row, without the icon — the round-video list draws its own picture in
    /// that place and wants the rest to line up with everything else.
    struct Labels: View {
        let title: Text
        var detail: Text?
        let timestamp: Date

        var body: some View {
            VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                title
                    .font(.subheadline)
                    .lineLimit(1)

                HStack(spacing: Theme.Spacing.close) {
                    if let detail {
                        detail
                    }
                    Text(RoomTimestamp.label(for: timestamp))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
    }
}

/// One address out of the history, and the words it was posted with.
struct LinkItem: Identifiable, Equatable {
    /// The message it came from plus the address itself: one message can carry several links, and
    /// the message ID alone would make them the same row.
    let id: String
    let url: URL
    let context: String
    let timestamp: Date

    static func items(from messages: [Message]) -> [LinkItem] {
        messages.flatMap { message -> [LinkItem] in
            let body: String? = switch message.kind {
            case let .text(body): body
            case let .notice(body): body
            case let .emote(body): body
            default: nil
            }
            guard let body else { return [] }

            return RichText.links(in: body).map { url in
                LinkItem(id: message.id + "|" + url.absoluteString,
                         url: url,
                         context: body,
                         timestamp: message.timestamp)
            }
        }
    }
}
