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

    var body: some View {
        AlbumBubbleLayout {
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
        AlbumMosaicLayout(ratios: items.map { CGFloat($0.captioned?.aspectRatio ?? 1) },
                          windowHeight: timelineHeight > 0 ? timelineHeight * Theme.Size.albumHeightFraction : nil) {
            ForEach(Array(items.indices), id: \.self) { index in
                tile(items[index], at: index)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            }
        }
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
                            .padding(.vertical, Theme.Spacing.withinRun)
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

/// The set over its caption, as wide as the two of them need — and the set is always the full width.
///
/// Not a `VStack` over a set of a fixed width, which is how words that fitted came to be folded. A
/// row hands out only a share of its width to something that will not get narrower, the set then
/// stood wider than it had been offered, and the caption was still laid out in the offer: "Почему я
/// не удивлена" in two lines under a picture three times as wide. And the other way round, a long
/// caption made the bubble wider and left the picture standing short of its edge.
///
/// So the width is decided here, once, from what the caption would like, and both are given it.
struct AlbumBubbleLayout: Layout {
    private func width(_ proposal: ProposedViewSize, _ subviews: Subviews) -> CGFloat {
        guard subviews.count > 1 else { return Theme.Size.picture }
        let wanted = subviews[1].sizeThatFits(.unspecified).width
        return max(Theme.Size.picture,
                   min(wanted, proposal.width ?? .infinity, Theme.Size.captionedPictureMaximum))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = width(proposal, subviews)
        let offer = ProposedViewSize(width: width, height: nil)
        return CGSize(width: width,
                      height: subviews.reduce(0) { $0 + $1.sizeThatFits(offer).height })
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let offer = ProposedViewSize(width: bounds.width, height: nil)
        var y = bounds.minY
        for subview in subviews {
            subview.place(at: CGPoint(x: bounds.minX, y: y), proposal: offer)
            y += subview.sizeThatFits(offer).height
        }
    }
}

/// The pictures of a set, at whatever width they are given — see `AlbumMosaic`.
private struct AlbumMosaicLayout: Layout {
    let ratios: [CGFloat]

    /// The most of the window a set may take, when the window has been measured.
    let windowHeight: CGFloat?

    private func frames(width: CGFloat) -> [CGRect] {
        // Wider than usual is the same shape, larger: only the window holds it back.
        let byShape = Theme.Size.pictureMaxHeight * width / Theme.Size.picture
        return AlbumMosaic.frames(ratios: ratios,
                                  width: width,
                                  spacing: Theme.Spacing.albumGap,
                                  maxHeight: min(byShape, windowHeight ?? byShape))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? Theme.Size.picture
        return CGSize(width: width, height: frames(width: width).map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, frame) in zip(subviews, frames(width: bounds.width)) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          proposal: ProposedViewSize(frame.size))
        }
    }
}
