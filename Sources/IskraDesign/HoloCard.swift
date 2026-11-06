import SwiftUI

/// The rainbow that shows through the white of the QR card when it is turned — Threads' invitation
/// card, with the spark in place of their logo. A field of small spark outlines on a slant, and a
/// pastel rainbow showing through them that slides across as the card turns.
///
/// Two numbers drive it and the card works them out from its own angle: `phase` moves the colours,
/// `strength` is how much of it there is. Face on it is barely there; tilted it comes up, which is
/// what makes it look like foil and not like a printed pattern.
///
/// In `IskraDesign` because it knows nothing but a shape and some colours.
public struct HoloWatermark: View {
    let phase: Double
    let strength: Double

    public init(phase: Double, strength: Double) {
        self.phase = phase
        self.strength = strength
    }

    /// Pastels and not a full spectrum: on white, saturated colours read as a print, not a sheen.
    private static let colors: [Color] = [
        Color(red: 1.00, green: 0.62, blue: 0.82),
        Color(red: 1.00, green: 0.86, blue: 0.50),
        Color(red: 0.62, green: 0.94, blue: 0.74),
        Color(red: 0.56, green: 0.84, blue: 1.00),
        Color(red: 0.78, green: 0.66, blue: 1.00),
        Color(red: 1.00, green: 0.62, blue: 0.82),
    ]

    public var body: some View {
        // The gradient is twice the card across and slides by up to half of that, so its ends
        // never come into view whichever way the card is turned.
        let shift = sin(phase) * 0.5
        LinearGradient(colors: Self.colors,
                       startPoint: UnitPoint(x: -0.5 + shift, y: -0.5 + shift),
                       endPoint: UnitPoint(x: 1.5 + shift, y: 1.5 + shift))
            .mask { SparkField() }
            .opacity(strength)
            .drawingGroup()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// The sparks the rainbow shows through. A view of its own with nothing in it to change, so that
/// SwiftUI sees it as unchanged on every frame of the card turning and does not draw the thousand
/// outlines again — only the gradient behind them moves.
private struct SparkField: View {
    /// How far the sparks are slanted, as on the card in the screenshots.
    private static let slant = Angle.degrees(-20)

    var body: some View {
        Canvas { context, size in
            let step = Theme.Size.watermarkStep
            let glyph = step * 0.7
            let spark = SparkGlyph().path(in: CGRect(x: -glyph / 2, y: -glyph / 2, width: glyph, height: glyph))

            context.translateBy(x: size.width / 2, y: size.height / 2)
            context.rotate(by: Self.slant)
            // Turned, the card's corners reach further than its half-width; the grid has to cover
            // the diagonal or the corners come out bare.
            let reach = (size.width * size.width + size.height * size.height).squareRoot() / 2 + step
            let count = Int(reach / step)
            for row in -count...count {
                // Every other row half a step along, so the sparks sit in a brick pattern and no
                // straight line of them runs down the card.
                let offset = row.isMultiple(of: 2) ? 0 : step / 2
                for column in -count...count {
                    let point = CGPoint(x: CGFloat(column) * step + offset, y: CGFloat(row) * step)
                    context.stroke(spark.offsetBy(dx: point.x, dy: point.y),
                                   with: .color(.black), lineWidth: 1)
                }
            }
        }
    }
}
