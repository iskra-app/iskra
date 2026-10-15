import SwiftUI
import IskraCore
import IskraDesign

/// Photos and videos sent together, in one bubble — see `Album` for which ones, and `AlbumMosaic`
/// for where each goes.
///
/// One bubble, in the fill a text message from the same person has — the set framed in it, the
/// caption under it in the bubble's own ink, padded as a text message's words are. Each tile opens the viewer on itself, with the rest of the room's
/// pictures either side, so swiping on from the third photo of an album goes to the fourth.
struct AlbumBubble: View {
    let items: [Message]

    /// The edge drawn around the album — the bubble it stands in for, or nothing at all.
    let style: BubbleStyle

    /// The words under it, already painted by `MessageContent` — links and mentions live.
    var caption: AnyView?

    @Environment(\.timelineHeight) private var timelineHeight
    @Environment(\.roomMedia) private var roomMedia
    @Environment(\.coversRoom) private var coversRoom

    @State private var opened: OpenedAlbum?

    private struct OpenedAlbum: Identifiable {
        let items: [MediaItem]
        let index: Int
        var id: String { items[index].id }
    }

    private var width: CGFloat { Theme.Size.picture }

    private var maxHeight: CGFloat {
        (timelineHeight > 0 ? timelineHeight : width * 2) * Theme.Size.albumHeightFraction
    }

    private var frames: [CGRect] {
        AlbumMosaic.frames(ratios: items.map { CGFloat($0.captioned?.aspectRatio ?? 1) },
                           width: width,
                           spacing: Theme.Spacing.albumGap,
                           maxHeight: maxHeight)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            mosaic

            if let caption {
                caption
                    .font(.body)
                    .padding(.horizontal, Theme.Spacing.captionHorizontal)
                    .padding(.top, Theme.Spacing.albumCaptionTop)
                    .padding(.bottom, Theme.Spacing.captionVertical)
            }
        }
        .padding(Theme.Spacing.tight)
        .bubbleFill(style)
        // No outline: the bubble's own fill is the edge, as it is for words.
        .clipShape(BubbleShape())
        .contentShape(BubbleShape())
        #if os(iOS)
        .fullScreenCover(item: $opened) { opened in
            MediaPager(items: opened.items, startIndex: opened.index)
                .presentationBackground(.black)
        }
        .onChange(of: opened != nil) { _, isOpen in coversRoom(isOpen) }
        #else
        .sheet(item: $opened) { opened in
            MediaPager(items: opened.items, startIndex: opened.index)
        }
        #endif
    }

    private var mosaic: some View {
        let frames = frames
        let height = frames.map(\.maxY).max() ?? 0
        return ZStack(alignment: .topLeading) {
            ForEach(Array(zip(items.indices, frames)), id: \.0) { index, frame in
                tile(items[index], at: index)
                    .frame(width: frame.width, height: frame.height)
                    .clipped()
                    .offset(x: frame.minX, y: frame.minY)
            }
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .clipShape(UnevenRoundedRectangle(
            topLeadingRadius: Theme.Radius.picture,
            bottomLeadingRadius: caption == nil ? Theme.Radius.picture : Theme.Radius.pictureAboveCaption,
            bottomTrailingRadius: caption == nil ? Theme.Radius.picture : Theme.Radius.pictureAboveCaption,
            topTrailingRadius: Theme.Radius.picture,
            style: .continuous))
    }

    @ViewBuilder
    private func tile(_ message: Message, at index: Int) -> some View {
        if let attachment = message.captioned {
            let isVideo = { if case .video = message.kind { true } else { false } }()
            MediaThumbnail(attachment: attachment,
                           obeysAutoDownload: true)
                .overlay {
                    if isVideo {
                        Image(systemName: "play.circle.fill")
                            .font(.title)
                            .foregroundStyle(.white.opacity(0.9))
                            .shadow(radius: 8)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if isVideo, let duration = attachment.duration {
                        Text(Duration.seconds(duration), format: .time(pattern: .minuteSecond))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, Theme.Spacing.close)
                            .padding(.vertical, 2)
                            .background(.black.opacity(Theme.Backdrop.plate), in: Capsule())
                            .padding(Theme.Spacing.tight)
                    }
                }
                .contentShape(.rect)
                .messageTap { open(at: index) }
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { open(at: index) }
                .accessibilityLabel(Text(isVideo ? Strings.Message.Media.video : Strings.Message.Media.photo))
                .accessibilityHint(Text(Strings.Message.Media.openFullScreen))
        }
    }

    /// The viewer, on this tile — among all the room's pictures where the room offers them, among
    /// the album's own where it does not.
    private func open(at index: Int) {
        let id = items[index].id
        let all = roomMedia?.viewable() ?? []
        if let found = all.firstIndex(where: { $0.id == id }) {
            opened = OpenedAlbum(items: all, index: found)
            return
        }
        let own = MediaItem.items(from: items)
        opened = OpenedAlbum(items: own, index: own.firstIndex { $0.id == id } ?? 0)
    }
}
