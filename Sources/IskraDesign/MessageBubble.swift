import SwiftUI

/// The shape of a message bubble: round on every corner, the same on both sides.
///
/// This used to tuck the one corner on the sender's own side, iMessage-style. It no
/// longer does. The radius is large enough that a one-line message comes out as a
/// capsule — SwiftUI clamps a corner radius to half the shorter side — and only a
/// message long enough to wrap reads as a rounded rectangle. That is the Instagram
/// shape, and it is what the app wants: the side a message is on already says who
/// sent it, so the corners do not have to say it a second time.
public struct BubbleShape: Shape, InsettableShape {
    /// Insettable so that a *stroked* bubble can be drawn inside its own bounds. A plain
    /// `stroke` straddles the edge and spills half its width outside the row's layout,
    /// which nothing clips and everything below has to make room for; `strokeBorder` needs
    /// this. See `deletedBubble`.
    private var inset: CGFloat = 0

    public init() {}

    public func path(in rect: CGRect) -> Path {
        RoundedRectangle(cornerRadius: Theme.Radius.bubble - inset, style: .continuous)
            .path(in: rect.insetBy(dx: inset, dy: inset))
    }

    public func inset(by amount: CGFloat) -> Self {
        var shape = self
        shape.inset += amount
        return shape
    }
}

/// What a message is dressed in.
///
/// Not *whose it is*. That is what this used to be — a `Bool` called `isOwn` — and the two are
/// the same question only for as long as there is exactly one way to draw a conversation. The
/// compact timeline dresses every message in nothing, the reader's own included, and a `Bool`
/// has no third answer to give.
///
/// The distinction earns its keep in `.plain`: because a bubble that draws no fill and spends
/// no padding is the *identity*, the fourteen kinds of message can be drawn by one `switch`
/// that never asks which timeline it is in. The wrapper learned a third answer so that
/// everything inside it could stay exactly as it was. See `MessageContent`.
public enum BubbleStyle: Sendable, Hashable {
    /// The reader's own: the accent they picked, and whatever stays readable on it.
    case own

    /// Somebody else's: the neutral grey.
    case incoming

    /// Nothing at all — no fill, no padding, the ordinary ink.
    case plain
}

/// The fill and the padding of a bubble.
///
/// A modifier rather than a plain `View` extension, because the colour of your own bubble
/// is the accent the user picked and that is read from the environment — which a free
/// function on `View` has no access to.
struct MessageBubble: ViewModifier {
    let style: BubbleStyle

    @Environment(\.accent) private var accent

    /// Whether the conversation is standing on a wallpaper, which is what decides between a
    /// hierarchical fill and an opaque one — see `EnvironmentValues.hasWallpaper`.
    @Environment(\.hasWallpaper) private var hasWallpaper

    /// Whether this bubble has been lifted off the page it was drawn on — see
    /// `EnvironmentValues.bubbleIsLifted`.
    @Environment(\.bubbleIsLifted) private var isLifted

    /// Wider than the padding above and below, so the words sit in the middle of the
    /// bubble rather than pressed against its rounded sides — the corners eat into
    /// the left and right edges in a way they do not eat into the top and bottom.
    /// Both come off the same scale of fours, so the gap between them holds when
    /// either one moves.
    private var horizontal: CGFloat { style == .plain ? 0 : Theme.Spacing.roomy }
    private var vertical: CGFloat { style == .plain ? 0 : Theme.Spacing.normal }

    /// One line of body text, as tall as Dynamic Type makes it — what a one-line bubble's height
    /// is made of, and so what its narrowest width has to match.
    @ScaledMetric(relativeTo: .body) private var lineHeight: CGFloat = Theme.Size.bodyLine

    /// Never narrower than tall. "ок" in a bubble two letters wide came out as a thin upright
    /// pill; at least as wide as a line is high, the shortest message is a circle — Telegram's —
    /// and the words sit in the middle of it.
    private var minimumContentWidth: CGFloat {
        guard style != .plain else { return 0 }
        return max(0, lineHeight + vertical * 2 - horizontal * 2)
    }

    private var fill: AnyShapeStyle {
        switch style {
        case .own: accent.bubble(onWallpaper: hasWallpaper)
        case .incoming: AnyShapeStyle(hasWallpaper ? Color.incomingBubbleOnWallpaper : Color.incomingBubble)
        case .plain: AnyShapeStyle(.clear)
        }
    }

    func body(content: Content) -> some View {
        let shape = BubbleShape()

        return content
            .frame(minWidth: minimumContentWidth)
            .padding(.horizontal, horizontal)
            .padding(.vertical, vertical)
            .foregroundStyle(style == .own ? accent.onBubble : AnyShapeStyle(.primary))
            .background(fill, in: shape)
            // The page, under the fill, when there is no page — see `bubbleIsLifted`.
            .background(isLifted && style != .plain ? Color.page : Color.clear, in: shape)
            // Lets a long-press menu and drag preview take the bubble's shape rather
            // than a rectangle around it.
            //
            // Plain spends no padding, and the hit area would collapse onto the glyphs with
            // it — so it is padded out, shaped, and padded back in. The gesture that needs
            // this is the double tap: settings promises it on every message, and on a plain
            // "Да" the promise would come down to landing a finger inside two letters. The
            // same trick, and the same reason, as `SendFailureBadge.touchInset`.
            .padding(.horizontal, style == .plain ? Theme.Spacing.roomy : 0)
            .padding(.vertical, style == .plain ? Theme.Spacing.normal : 0)
            .contentShape(shape)
            .padding(.horizontal, style == .plain ? -Theme.Spacing.roomy : 0)
            .padding(.vertical, style == .plain ? -Theme.Spacing.normal : 0)
    }
}

/// A message's fill and ink without its padding — for a bubble that lays out its own insides, as an
/// album does (`AlbumBubble`): the pictures go to within a hairline of the edge, and the caption
/// under them is padded by hand to sit where a text message's words would.
struct BubbleFill: ViewModifier {
    let style: BubbleStyle

    @Environment(\.accent) private var accent
    @Environment(\.hasWallpaper) private var hasWallpaper
    @Environment(\.bubbleIsLifted) private var isLifted

    private var fill: AnyShapeStyle {
        switch style {
        case .own: accent.bubble(onWallpaper: hasWallpaper)
        case .incoming: AnyShapeStyle(hasWallpaper ? Color.incomingBubbleOnWallpaper : Color.incomingBubble)
        case .plain: AnyShapeStyle(.clear)
        }
    }

    func body(content: Content) -> some View {
        let shape = BubbleShape()
        return content
            .foregroundStyle(style == .own ? accent.onBubble : AnyShapeStyle(.primary))
            .background(fill, in: shape)
            .background(isLifted && style != .plain ? Color.page : Color.clear, in: shape)
    }
}

/// The outline around a picture, in the colour that message's bubble would have been.
///
/// A photo has no bubble — it *is* the bubble — so a picture whose edges happen to match
/// the background behind them simply ends, and nothing says where. The outline is the
/// bubble the picture replaced, reduced to its edge: the sender's own accent on their
/// side, the neutral grey on the other, so a photo still reads as belonging to the same
/// side of the conversation as the words around it.
struct PictureBorder: ViewModifier {
    let style: BubbleStyle

    @Environment(\.accent) private var accent
    @Environment(\.hasWallpaper) private var hasWallpaper

    func body(content: Content) -> some View {
        content.overlay {
            // `strokeBorder`, not `stroke`: the picture is clipped to this same shape, and
            // a line straddling that edge would have its outer half cut away and come out
            // half as thick as asked for — see `BubbleShape.inset`.
            //
            // Plain draws no edge at all. The outline stands in for the bubble a picture
            // replaced, and where there are no bubbles there is nothing for it to stand in
            // for — see `BubbleStyle`.
            BubbleShape()
                .strokeBorder(border, lineWidth: Theme.Border.hairline)
        }
    }

    private var border: AnyShapeStyle {
        switch style {
        case .own: accent.bubble(onWallpaper: hasWallpaper)
        case .incoming: AnyShapeStyle(hasWallpaper ? Color.incomingBubbleOnWallpaper : Color.incomingBubble)
        case .plain: AnyShapeStyle(.clear)
        }
    }
}

public extension View {
    /// The bubble's colours and nothing else — see `BubbleFill`.
    func bubbleFill(_ style: BubbleStyle) -> some View {
        modifier(BubbleFill(style: style))
    }

    /// Draws the edge of the bubble a picture stands in for. See `PictureBorder`.
    func pictureBorder(_ style: BubbleStyle) -> some View {
        modifier(PictureBorder(style: style))
    }

    /// Dresses a message in its bubble — or, on `.plain`, in nothing at all.
    ///
    /// Note what this does *not* do: apply glass. Bubbles are content, and the HIG
    /// reserves Liquid Glass for the navigation layer. A glass bubble would also be
    /// unreadable over a photo, which is exactly where bubbles end up.
    func messageBubble(_ style: BubbleStyle) -> some View {
        modifier(MessageBubble(style: style))
    }

    /// The bubble a message leaves behind once it has been taken back.
    ///
    /// The same shape and the same padding as a real one — a redaction keeps the row and
    /// replaces what was in it, so the bubble has to collapse into this rather than be
    /// swapped for something of another kind — but drawn as an outline, and a broken one.
    ///
    /// The fill is what a bubble uses to say a message is *there*: a colour on your own, a
    /// grey on someone else's, either way a solid thing you can read words off. There are no
    /// words here and nothing behind them, and filling the shape anyway would give an absence
    /// the same weight in the conversation as everything still in it. An empty outline says
    /// what happened without taking up a voice, and the dashes are the oldest way there is of
    /// drawing a thing that is missing rather than a thing that is quiet.
    ///
    /// All of which is an argument about *bubbles*, and it stops where they do. The dashes read
    /// as the ghost of a bubble only in a timeline that has bubbles to be the ghost of; dropped
    /// into the plain column they are simply the one outlined thing on the screen, which makes
    /// the deleted message the loudest item in a conversation it should be the quietest item in.
    /// So `.plain` says it the way that column says everything else: in words, and in the grey
    /// the column keeps for things that are not somebody talking.
    func deletedBubble(_ style: BubbleStyle) -> some View {
        let shape = BubbleShape()
        let isPlain = style == .plain

        return padding(.horizontal, isPlain ? 0 : Theme.Spacing.roomy)
            .padding(.vertical, isPlain ? 0 : Theme.Spacing.normal)
            .foregroundStyle(.secondary)
            .overlay {
                if !isPlain {
                    shape.strokeBorder(.secondary,
                                       style: StrokeStyle(lineWidth: Theme.Border.hairline,
                                                          dash: Theme.Border.dash))
                        // Quieter than the words inside it: the outline is the frame around the
                        // sentence, not a second thing competing with it to be read.
                        .opacity(0.5)
                }
            }
            // A tombstone keeps its menu — the two dates are the only thing it still knows — so
            // it keeps a target big enough to press, padding out and back in the way a plain
            // bubble does. See `MessageBubble.body`.
            .padding(.horizontal, isPlain ? Theme.Spacing.roomy : 0)
            .padding(.vertical, isPlain ? Theme.Spacing.normal : 0)
            .contentShape(shape)
            .padding(.horizontal, isPlain ? -Theme.Spacing.roomy : 0)
            .padding(.vertical, isPlain ? -Theme.Spacing.normal : 0)
    }
}

public extension EnvironmentValues {
    /// Whether the bubble being drawn has been picked up off the conversation — the copy the
    /// message menu lifts over a darkened, blurred room.
    ///
    /// A bubble's fill is not a colour, it is a *tint*: five percent of the foreground for
    /// somebody else's message, sixteen for your own on the colourless theme. On the page that is
    /// a grey; lifted over the menu's curtain it is five percent of the curtain, and the bubble
    /// that was grey a moment ago is suddenly see-through. So a lifted bubble carries the page
    /// with it, underneath the tint, and comes out exactly the colour it was. Over a wallpaper the
    /// fills are opaque already and the page underneath them changes nothing.
    @Entry var bubbleIsLifted: Bool = false
}

public extension Color {
    /// The page a conversation is drawn on when it has no wallpaper — the system's own
    /// background, named as a colour rather than reached through `ShapeStyle.background`. That
    /// one resolves through the environment's `backgroundStyle`, and the whole point of the page
    /// under a lifted bubble is that it is opaque whatever the environment around it says.
    ///
    /// On a Mac it is the phone's page, not the window's: white, and in the dark a near-black —
    /// not the phone's pure black, which on a window beside other windows read as a hole, and not
    /// the window's own grey either, which made the Mac app a different app from the one on the
    /// phone.
    static var page: Color {
        #if canImport(UIKit)
        Color(uiColor: .systemBackground)
        #elseif canImport(AppKit)
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(srgbRed: 0x18 / 255, green: 0x18 / 255, blue: 0x1A / 255, alpha: 1)
                : .white
        })
        #else
        .white
        #endif
    }

    /// The page a form stands on — the phone's grouped background: a light grey under white cards,
    /// and in the dark a shade below `page`, so the cards stand off it as they do on the phone. On a
    /// Mac, where forms otherwise sit on the window's grey.
    static var groupedPage: Color {
        #if canImport(UIKit)
        Color(uiColor: .systemGroupedBackground)
        #elseif canImport(AppKit)
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(srgbRed: 0x12 / 255, green: 0x12 / 255, blue: 0x14 / 255, alpha: 1)
                : NSColor(srgbRed: 0xF2 / 255, green: 0xF2 / 255, blue: 0xF7 / 255, alpha: 1)
        })
        #else
        .white
        #endif
    }
}
