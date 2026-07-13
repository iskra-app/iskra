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

/// The fill and the padding of a bubble.
///
/// A modifier rather than a plain `View` extension, because the colour of your own bubble
/// is the accent the user picked and that is read from the environment — which a free
/// function on `View` has no access to.
struct MessageBubble: ViewModifier {
    let isOwn: Bool

    @Environment(\.accent) private var accent

    func body(content: Content) -> some View {
        let shape = BubbleShape()

        // Wider than the padding above and below, so the words sit in the middle of the
        // bubble rather than pressed against its rounded sides — the corners eat into
        // the left and right edges in a way they do not eat into the top and bottom.
        // Both come off the same scale of fours, so the gap between them holds when
        // either one moves.
        return content
            .padding(.horizontal, Theme.Spacing.roomy)
            .padding(.vertical, Theme.Spacing.normal)
            .foregroundStyle(isOwn ? accent.onBubble : AnyShapeStyle(.primary))
            .background(isOwn ? accent.bubble : AnyShapeStyle(Color.incomingBubble),
                        in: shape)
            // Lets a long-press menu and drag preview take the bubble's shape rather
            // than a rectangle around it.
            .contentShape(shape)
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
    let isOwn: Bool

    @Environment(\.accent) private var accent

    func body(content: Content) -> some View {
        content.overlay {
            // `strokeBorder`, not `stroke`: the picture is clipped to this same shape, and
            // a line straddling that edge would have its outer half cut away and come out
            // half as thick as asked for — see `BubbleShape.inset`.
            BubbleShape()
                .strokeBorder(isOwn ? accent.bubble : AnyShapeStyle(Color.incomingBubble),
                              lineWidth: Theme.Border.hairline)
        }
    }
}

public extension View {
    /// Draws the edge of the bubble a picture stands in for. See `PictureBorder`.
    func pictureBorder(isOwn: Bool) -> some View {
        modifier(PictureBorder(isOwn: isOwn))
    }

    /// Dresses a message in its bubble.
    ///
    /// Note what this does *not* do: apply glass. Bubbles are content, and the HIG
    /// reserves Liquid Glass for the navigation layer. A glass bubble would also be
    /// unreadable over a photo, which is exactly where bubbles end up.
    func messageBubble(isOwn: Bool) -> some View {
        modifier(MessageBubble(isOwn: isOwn))
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
    func deletedBubble() -> some View {
        let shape = BubbleShape()

        return padding(.horizontal, Theme.Spacing.roomy)
            .padding(.vertical, Theme.Spacing.normal)
            .foregroundStyle(.secondary)
            .overlay {
                shape.strokeBorder(.secondary,
                                   style: StrokeStyle(lineWidth: Theme.Border.hairline,
                                                      dash: Theme.Border.dash))
                    // Quieter than the words inside it: the outline is the frame around the
                    // sentence, not a second thing competing with it to be read.
                    .opacity(0.5)
            }
            .contentShape(shape)
    }
}
