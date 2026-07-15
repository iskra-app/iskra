import SwiftUI
import IskraCore
import IskraDesign

/// One piece of media in a room's gallery — a photo, a video, or a file — flattened out of the
/// message it arrived in so the gallery can lay them out without the conversation around them.
struct MediaItem: Identifiable, Equatable {
    let id: String
    let attachment: Attachment
    let isVideo: Bool
    let isFile: Bool
    let sender: String
    let timestamp: Date

    /// Pulls the media out of a run of messages, newest first as the timeline holds them. Text,
    /// voice notes, locations and the rest are not media the gallery shows, so they fall away.
    static func items(from messages: [Message]) -> [MediaItem] {
        messages.compactMap { message in
            switch message.kind {
            case let .image(attachment):
                item(message, attachment, isVideo: false, isFile: false)
            case let .video(attachment):
                item(message, attachment, isVideo: true, isFile: false)
            case let .videoNote(attachment):
                item(message, attachment, isVideo: true, isFile: false)
            case let .file(attachment):
                item(message, attachment, isVideo: false, isFile: true)
            default:
                nil
            }
        }
    }

    private static func item(_ message: Message, _ attachment: Attachment,
                             isVideo: Bool, isFile: Bool) -> MediaItem {
        MediaItem(id: message.id, attachment: attachment, isVideo: isVideo, isFile: isFile,
                  sender: message.senderName, timestamp: message.timestamp)
    }
}

/// Everything a room has sent as media, on one screen — a grid for the pictures and videos, a list
/// for the files — so you can find a photo from March without scrolling March.
///
/// It reads from the open timeline, so it shows what has been loaded and grows as the history is
/// paged back: the same rows the conversation is drawn from, filtered to their attachments. Tapping
/// a picture opens the full viewer, swipeable across the whole grid.
struct RoomGalleryView: View {
    let timeline: TimelineStore

    @State private var openedAt: Int?

    private var messages: [Message] {
        timeline.rows.compactMap { row in
            if case let .message(message) = row { message } else { nil }
        }
    }

    private var items: [MediaItem] { MediaItem.items(from: messages) }
    private var pictures: [MediaItem] { items.filter { !$0.isFile } }
    private var files: [MediaItem] { items.filter(\.isFile) }

    private let columns = [GridItem(.adaptive(minimum: 96), spacing: Theme.Spacing.tight)]

    var body: some View {
        ScrollView {
            if !pictures.isEmpty {
                LazyVGrid(columns: columns, spacing: Theme.Spacing.tight) {
                    ForEach(Array(pictures.enumerated()), id: \.element.id) { index, item in
                        Button {
                            openedAt = index
                        } label: {
                            MediaThumbnail(attachment: item.attachment)
                                .aspectRatio(1, contentMode: .fill)
                                .frame(minWidth: 0, maxWidth: .infinity)
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
                .padding(.horizontal, Theme.Spacing.normal)
            }

            if !files.isEmpty {
                VStack(spacing: 0) {
                    ForEach(files) { item in
                        HStack(spacing: Theme.Spacing.normal) {
                            Image(systemName: "doc")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(item.attachment.filename)
                                    .font(.subheadline)
                                    .lineLimit(1)
                                Text(RoomTimestamp.label(for: item.timestamp))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(Theme.Spacing.normal)
                    }
                }
            }

            // Media lives in the history, and the history is paged. Reaching for more is the same
            // pagination the conversation uses — it just fills the grid instead of the chat.
            if timeline.canLoadMore {
                Button {
                    Task { await timeline.loadMore() }
                } label: {
                    if timeline.isPaginating {
                        ProgressView()
                    } else {
                        Text(Strings.Room.galleryLoadEarlier)
                    }
                }
                .padding(Theme.Spacing.roomy)
            }
        }
        .navigationTitle(Text(Strings.Room.sharedMedia))
        .toolbarTitleDisplayMode(.inline)
        .overlay { emptyState }
        .sheet(item: Binding(get: { openedAt.map { OpenedIndex(value: $0) } },
                             set: { openedAt = $0?.value })) { opened in
            MediaPager(items: pictures, startIndex: opened.value)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if items.isEmpty {
            ContentUnavailableView(String(app: Strings.Room.sharedMediaEmptyTitle),
                                   systemImage: "photo.on.rectangle",
                                   description: Text(Strings.Room.sharedMediaEmptyMessage))
        }
    }
}

/// A sheet needs an `Identifiable` item, and a bare index is not one — two opens at the same index
/// would be "the same" and the second would not present. This wraps it.
private struct OpenedIndex: Identifiable {
    let value: Int
    var id: Int { value }
}

/// The full-screen viewer, swipeable across a room's pictures and videos — Telegram's horizontal
/// paging. Each page is the same `MediaViewer` a single tap opens, so zoom, share, save and
/// drag-to-dismiss all come along; the page swipe is the one thing added on top.
struct MediaPager: View {
    let items: [MediaItem]
    @State var index: Int

    init(items: [MediaItem], startIndex: Int) {
        self.items = items
        _index = State(initialValue: startIndex)
    }

    var body: some View {
        TabView(selection: $index) {
            ForEach(Array(items.enumerated()), id: \.element.id) { offset, item in
                MediaViewer(attachment: item.attachment,
                            isVideo: item.isVideo,
                            sender: item.sender,
                            timestamp: item.timestamp)
                    .tag(offset)
            }
        }
        #if os(iOS)
        .tabViewStyle(.page(indexDisplayMode: .never))
        #endif
    }
}
