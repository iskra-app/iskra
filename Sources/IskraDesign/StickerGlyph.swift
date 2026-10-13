import SwiftUI

/// The sticker button's icon: a rounded square with its bottom-right corner peeled back.
///
/// Drawn, because SF Symbols has no sticker — and the smiley that stood in for one said "emoji",
/// which is the keyboard's button, not this one. The peeled corner is the mark every messenger
/// uses for stickers, Telegram's included, so it reads as "stickers" without a word.
///
/// Stroked at the weight of the symbols beside it and sized by the font, like an `Image` would be.
public struct StickerGlyph: View {
    @ScaledMetric(relativeTo: .body) private var side: CGFloat = Theme.Size.glyph

    public init() {}

    public var body: some View {
        StickerOutline()
            .stroke(style: StrokeStyle(lineWidth: side / 12, lineCap: .round, lineJoin: .round))
            .frame(width: side, height: side)
            .accessibilityHidden(true)
    }
}

/// The outline itself: the square, the cut across its corner, and the flap folded over.
struct StickerOutline: Shape {
    func path(in rect: CGRect) -> Path {
        let inset = rect.insetBy(dx: rect.width / 12, dy: rect.height / 12)
        let radius = inset.width * 0.28
        let peel = inset.width * 0.42
        let (minX, minY, maxX, maxY) = (inset.minX, inset.minY, inset.maxX, inset.maxY)

        var path = Path()
        // From the top-left corner, clockwise, to where the peel begins on the right edge.
        path.move(to: CGPoint(x: minX + radius, y: minY))
        path.addLine(to: CGPoint(x: maxX - radius, y: minY))
        path.addQuadCurve(to: CGPoint(x: maxX, y: minY + radius), control: CGPoint(x: maxX, y: minY))
        path.addLine(to: CGPoint(x: maxX, y: maxY - peel))
        // The cut across the corner.
        path.addLine(to: CGPoint(x: maxX - peel, y: maxY))
        path.addLine(to: CGPoint(x: minX + radius, y: maxY))
        path.addQuadCurve(to: CGPoint(x: minX, y: maxY - radius), control: CGPoint(x: minX, y: maxY))
        path.addLine(to: CGPoint(x: minX, y: minY + radius))
        path.addQuadCurve(to: CGPoint(x: minX + radius, y: minY), control: CGPoint(x: minX, y: minY))

        // The flap: folded back from the cut, its corner resting inside the sticker.
        path.move(to: CGPoint(x: maxX, y: maxY - peel))
        path.addQuadCurve(to: CGPoint(x: maxX - peel, y: maxY),
                          control: CGPoint(x: maxX - peel * 0.95, y: maxY - peel * 0.95))
        return path
    }
}
