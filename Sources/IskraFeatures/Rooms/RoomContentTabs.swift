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
/// It has been four things now, and the last two are the same idea with one thing fixed.
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
/// The missing idea was that the control does not have to be as wide as the screen; it has to be as
/// wide as *itself*, inside something that scrolls. The obvious spelling of that — a
/// `Picker(.segmented)` with `fixedSize` inside a SwiftUI `ScrollView` — compiles, looks right in a
/// screenshot, and does not scroll at all: a `UIScrollView` will not take a drag away from a
/// `UIControl`, so the finger never reaches it. There is nothing in the SwiftUI version of that
/// arrangement to argue with. See `ScrollingSegments`, which is the same control in a scroll view
/// that lets go — eighty lines of UIKit around a control that stays entirely Apple's.
///
/// A personal chat has three tabs, not six, and three words do fit: the control is then stretched to
/// the width of the row and sits there exactly as an ordinary segmented control would, with nothing
/// to scroll. Only when the words genuinely overflow does the strip become a strip.
///
/// One thing is given up and it is worth naming: nothing scrolls the chosen segment into view,
/// because the segments belong to the control. Choosing a tab that is half off the edge leaves it
/// half off the edge. That is a smaller price than a control that has stopped looking like the
/// system's.
struct RoomContentPicker: View {
    let tabs: [RoomContentTab]
    @Binding var selection: RoomContentTab

    // Its own margins, because the row it lives in has none — it is laid on the page rather than in
    // a card, so the inset that lines it up with the cards above and below is here.
    #if os(iOS)
    var body: some View {
        ScrollingSegments(titles: titles,
                          selection: index,
                          label: String(app: Strings.Room.Tabs.label))
            .padding(.horizontal, Theme.Spacing.roomy)
            .padding(.vertical, Theme.Spacing.close)
    }

    /// The words, already resolved. Pulled out of `body` rather than mapped inline: this is a
    /// `[String]` for UIKit, and building it inside a view builder is how a type-checker that has
    /// to prove a `some View` ends up proving something about localisation instead.
    private var titles: [String] {
        tabs.map { String(app: $0.title) }
    }
    #else
    // A Mac window is not a phone and the six words fit across it with room to spare, so the plain
    // control is the whole answer there — and a strip somebody would have to swipe with a trackpad
    // to read would be a worse one.
    var body: some View {
        Picker(selection: switching) {
            ForEach(tabs) { tab in
                Text(tab.title).tag(tab)
            }
        } label: {
            Text(Strings.Room.Tabs.label)
        }
        .pickerStyle(.segmented)
        // The control says what it is by what is in it, and the heading under it says which one is
        // open. A third label over the top would be the screen explaining its own furniture.
        .labelsHidden()
        .padding(.horizontal, Theme.Spacing.roomy)
        .padding(.vertical, Theme.Spacing.close)
    }
    #endif

    #if os(iOS)
    /// The selection as the UIKit control counts it — by position, which is the only thing a
    /// segmented control knows about its segments.
    ///
    /// Clamped rather than trusted on the way out. The tabs are rebuilt as a room gains its first
    /// file, and a control mid-rebuild can report a segment that the new list does not have.
    private var index: Binding<Int> {
        Binding(get: { tabs.firstIndex(of: selection) ?? 0 },
                set: { position in
                    guard tabs.indices.contains(position) else { return }
                    choose(tabs[position])
                })
    }

    #else
    /// The same, for the Mac's plain picker.
    ///
    /// The setter is written out as a closure rather than handed `choose` by name, and it has to
    /// be: passing the method reference straight to `Binding(get:set:)` crashes the compiler —
    /// `SmallVector unable to grow` out of IRGen, with no source line and no clue in it. The two
    /// spellings mean exactly the same thing, so the tidier one will look like an obvious
    /// simplification to whoever reads this next. It is not.
    private var switching: Binding<RoomContentTab> {
        Binding(get: { selection }, set: { choose($0) })
    }
    #endif

    /// The change to the list underneath, animated.
    ///
    /// The control animates its own fill whatever this does; what needs saying is that the *list*
    /// should cross-fade rather than jump — six different kinds of content in one place, swapped
    /// with no transition, reads as the screen being rebuilt under the reader.
    private func choose(_ tab: RoomContentTab) {
        guard tab != selection else { return }
        withAnimation(.easeInOut(duration: Theme.Timing.chrome)) { selection = tab }
    }
}

/// The end of a tab, which fetches more of the room's history for as long as it is on the screen —
/// Telegram's shared media, which has no button for this.
///
/// For as long as it is *seen*, not once: older history is thin on photographs and files, and a page
/// of twenty-five events very often adds nothing to the tab at all, so a single fetch on appearing
/// would leave the spinner sitting at the bottom of an unchanged list. It goes on paging until the
/// list has grown enough to push it off the screen, the room runs out of history, a page fails (the
/// store stops on that by itself — see `TimelineStore.loadMore`), or a ceiling is reached; scrolling
/// away and back starts it again.
///
/// Not the opening fetch — the conversation has that, explicitly, in `TimelineStore.open()`. This is
/// only the reader asking for *more*, by scrolling, which is the one way of asking the tab has.
struct AutoLoadEarlier: View {
    let timeline: TimelineStore
    @State private var isVisible = false

    var body: some View {
        ProgressView()
            .frame(maxWidth: .infinity)
            .padding(.vertical, Theme.Spacing.normal)
            .onAppear { isVisible = true }
            .onDisappear { isVisible = false }
            .task(id: isVisible) {
                guard isVisible else { return }
                var pages = 0
                while !Task.isCancelled, timeline.canLoadMore, !timeline.didFailToPaginate,
                      pages < Self.pagesPerVisit {
                    await timeline.loadMore()
                    pages += 1
                }
            }
            .accessibilityHidden(true)
    }

    /// Twenty pages is five hundred events: plenty for a screenful of anything, and a bound on how
    /// much history one glance at the bottom of a tab can pull in.
    private static let pagesPerVisit = 20
}

// MARK: - What each tab is made of

/// The pictures and the videos, as a grid — the arrangement the eye can actually search, which a
/// list of filenames is not.
///
/// Telegram's shared media: three square tiles to a row, edge to edge with a hairline between them
/// and no rounded corners — a contact sheet, not a set of cards — broken up by the month each run
/// was sent in, and a video wearing its length in the corner.
struct RoomMediaGrid: View {
    let items: [MediaItem]
    /// Opening one opens all of them, swipeable: the index is which one was pressed.
    @State private var openedAt: Int?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: Theme.Border.hairline), count: 3)

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(MonthGroups.group(items, by: \.timestamp), id: \.month) { group in
                MonthHeader(month: group.month)
                LazyVGrid(columns: columns, spacing: Theme.Border.hairline) {
                    ForEach(group.items, id: \.element.id) { index, item in
                        tile(item, at: index)
                    }
                }
            }
        }
        .sheet(item: Binding(get: { openedAt.map { OpenedIndex(value: $0) } },
                             set: { openedAt = $0?.value })) { opened in
            MediaPager(items: items, startIndex: opened.value)
        }
    }

    private func tile(_ item: MediaItem, at index: Int) -> some View {
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
                        // Square corners: tiles that touch, the way a contact sheet's do.
                        .clipped()
                        .overlay(alignment: .bottomTrailing) {
                            if item.isVideo { videoBadge(item) }
                        }
                }
                .buttonStyle(.plain)
    }

    /// The length in the corner of a video, Telegram's; a play mark where the length is unknown.
    @ViewBuilder
    private func videoBadge(_ item: MediaItem) -> some View {
        Group {
            if let duration = item.attachment.duration {
                Text(Duration.seconds(duration), format: .time(pattern: .minuteSecond))
                    .font(.caption2.weight(.semibold).monospacedDigit())
            } else {
                Image(systemName: "play.fill")
                    .font(.caption2)
            }
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.6), radius: 2)
        .padding(Theme.Spacing.tight)
    }
}

/// A month's heading over the run of things sent in it — "Октябрь 2026" — Telegram's way of breaking
/// up shared media, so a long history reads as a calendar and not as one undifferentiated wall.
struct MonthHeader: View {
    let month: Date

    var body: some View {
        Text(MonthGroups.label(for: month))
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, Theme.Spacing.roomy)
            .padding(.top, Theme.Spacing.normal)
            .padding(.bottom, Theme.Spacing.close)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Things sorted into the months they were sent in, newest month first, keeping each one's place in
/// the whole list — the index is what opens the right picture in the pager.
enum MonthGroups {
    struct Group<Item> {
        let month: Date
        let items: [(offset: Int, element: Item)]
    }

    static func group<Item>(_ items: [Item], by date: KeyPath<Item, Date>,
                            calendar: Calendar = .current) -> [Group<Item>] {
        var groups: [Group<Item>] = []
        var current: (month: Date, items: [(offset: Int, element: Item)])?

        for (index, item) in items.enumerated() {
            let month = calendar.dateInterval(of: .month, for: item[keyPath: date])?.start ?? item[keyPath: date]
            if current?.month != month {
                if let current { groups.append(Group(month: current.month, items: current.items)) }
                current = (month, [])
            }
            current?.items.append((index, item))
        }
        if let current { groups.append(Group(month: current.month, items: current.items)) }
        return groups
    }

    /// "Октябрь 2026": the month as it stands alone (`LLLL` — nominative in Russian, not "октября"),
    /// capitalised, and the year.
    static func label(for month: Date, locale: Locale = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate("LLLLyyyy")
        let text = formatter.string(from: month)
        return text.prefix(1).uppercased() + text.dropFirst()
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
                // Telegram's file row: a coloured tile with the extension on it, so a PDF is told
                // from a spreadsheet before a word of the name is read.
                HStack(spacing: Theme.Spacing.normal) {
                    FileTypeTile(filename: item.attachment.filename, failed: opener.failed)
                    RoomContentRow.Labels(title: Text(item.attachment.filename),
                                          detail: Text(item.sender),
                                          timestamp: item.timestamp)
                }
                .padding(.vertical, Theme.Spacing.tight)
                .contentShape(.rect)
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

/// The square beside a file in the files tab: its extension, on a colour that says what sort of file
/// it is — Telegram's.
struct FileTypeTile: View {
    let filename: String
    var failed = false

    var body: some View {
        RoundedRectangle(cornerRadius: Theme.Spacing.close, style: .continuous)
            .fill(failed ? Color.red : Self.tint(for: fileExtension))
            .frame(width: Theme.Size.avatar, height: Theme.Size.avatar)
            .overlay {
                if failed {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.white)
                } else {
                    Text(verbatim: fileExtension.isEmpty ? "FILE" : String(fileExtension.prefix(4)).uppercased())
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .minimumScaleFactor(0.6)
                        .padding(.horizontal, Theme.Spacing.tight)
                }
            }
            .accessibilityHidden(true)
    }

    private var fileExtension: String {
        (filename as NSString).pathExtension.lowercased()
    }

    static func tint(for fileExtension: String) -> Color {
        switch fileExtension {
        case "pdf": .red
        case "doc", "docx", "rtf", "pages", "txt", "md", "odt": .blue
        case "xls", "xlsx", "csv", "numbers", "ods": .green
        case "ppt", "pptx", "key", "odp": .orange
        case "zip", "rar", "7z", "tar", "gz": .brown
        case "mp3", "m4a", "ogg", "wav", "flac", "aac", "opus": .purple
        case "mp4", "mov", "mkv", "avi", "webm": .pink
        case "jpg", "jpeg", "png", "heic", "gif", "webp": .teal
        default: .gray
        }
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
