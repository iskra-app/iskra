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

/// The switch above the room's contents: the system's own segmented control, with the six words in
/// it, on a strip that can be pushed sideways when the words do not fit.
///
/// It has been four things now, and the last two are the same control with one thing changed.
///
/// It was a row of hand-drawn capsules on a sheet of glass inside a `Form` section, which is two
/// surfaces and a control — the grouped card drew a plate, the glass drew a second one on top of
/// it, and the pills drew a third. Then it was this control, standing straight on the page, which
/// fixed the floors and cost the words: a segmented control divides its width evenly between its
/// segments, and six Russian words do not fit in six sixths of a phone, so it was six glyphs
/// instead. Then it was the words again, as hand-drawn capsules — right about the words and wrong
/// about everything else, because every pixel of a control this app draws itself is a pixel that
/// will not match iOS 27.
///
/// The missing idea was that the control does not have to be as wide as the screen. It has to be as
/// wide as *itself*: `fixedSize` asks it for its own width — six equal segments, each as wide as the
/// longest word in it, nothing truncated — and a horizontal `ScrollView` is what lets that be wider
/// than the phone. The selection still slides the way the system slides it, the fill, the tint, the
/// focus ring, the keyboard handling and whatever Apple does to this control next are all theirs,
/// and no capsule here has to be kept in step with a system that has moved on.
///
/// `minWidth` is what makes it behave in both directions. A personal chat has three tabs, not six,
/// and three words do fit: the content is then stretched to the width of the scroll view and the
/// control sits centred in it with nothing to scroll, exactly as an ordinary segmented control
/// would. Only when the words genuinely overflow does the strip become a strip.
///
/// One thing is given up and it is worth naming: the strip cannot scroll the chosen segment into
/// view, because the segments belong to the control and there is nothing here to scroll *to*.
/// Choosing a tab that is already half off the edge leaves it half off the edge. That is a smaller
/// price than a control that stops looking like the system's.
struct RoomContentPicker: View {
    let tabs: [RoomContentTab]
    @Binding var selection: RoomContentTab

    /// How much room the row actually has. Measured rather than assumed, because it is the whole of
    /// the question this view asks: wider than the control means centre it and let nothing scroll,
    /// narrower means let it scroll.
    @State private var available: CGFloat = 0

    var body: some View {
        ScrollView(.horizontal) {
            Picker(selection: switching) {
                ForEach(tabs) { tab in
                    Text(tab.title).tag(tab)
                }
            } label: {
                Text(Strings.Room.Tabs.label)
            }
            .pickerStyle(.segmented)
            // The control says what it is by what is in it, and the heading under it says which one
            // is open. A third label over the top would be the screen explaining its own furniture.
            .labelsHidden()
            // Its own width, not the offered one. This is the line that buys the words back: without
            // it the control takes whatever the scroll view proposes and divides it six ways.
            .fixedSize()
            // Its own margins, because the row it lives in has none — it is laid on the page rather
            // than in a card, so the inset that lines it up with the cards above and below is here.
            // Inside the scroll view, so the control scrolls past the margin instead of being
            // clipped by it.
            .padding(.horizontal, Theme.Spacing.roomy)
            .padding(.vertical, Theme.Spacing.close)
            // See the note on `available`: this is what centres a control that fits and leaves one
            // that does not exactly as wide as it wants to be.
            .frame(minWidth: available, alignment: .center)
        }
        .scrollIndicators(.hidden)
        // Nothing to bounce against when there is nothing to scroll. Without this a segmented
        // control that fits the screen perfectly still rubber-bands under a finger, which reads as
        // a list that is hiding something.
        .scrollBounceBehavior(.basedOnSize)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { available = $0 }
    }

    /// The selection, with the change to the list underneath animated.
    ///
    /// The control animates its own fill whatever this does; what needs saying is that the *list*
    /// should cross-fade rather than jump — six different kinds of content in one place, swapped
    /// with no transition, reads as the screen being rebuilt under the reader.
    private var switching: Binding<RoomContentTab> {
        Binding(get: { selection },
                set: { tab in
                    guard tab != selection else { return }
                    withAnimation(.easeInOut(duration: Theme.Timing.chrome)) { selection = tab }
                })
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
