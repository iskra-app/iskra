import SwiftUI

/// The spark from the app icon, flat — one colour, no ground, no glass. Drawn where the icon itself
/// would be too much: in the middle of a QR code, at the size of a few of its squares.
///
/// The outline is `icons/iskra-spark-flat.svg`, copied in point for point (747 × 731), because a
/// SwiftPM resource directory has no asset catalog to load an SVG through — see `HomeIcon.previewURL`
/// for how a picture looked up by name goes missing without a word. Redrawing the spark means
/// changing that file and this one together.
///
/// The eyes are holes, so it is filled even-odd: `.fill(style: FillStyle(eoFill: true))`.
/// `eyes: false` is the same outline with nothing cut out of it — the spark with its eyes shut,
/// which is what `BlinkingSpark` shows for a moment. It is the outline of this path and not a
/// drawing of its own (`icons/iskra-spark-no-eyes.svg` is that outline, written out), so the two
/// frames of a blink differ by the eyes and by nothing else.
public struct SparkGlyph: Shape {
    public var eyes: Bool

    public init(eyes: Bool = true) {
        self.eyes = eyes
    }

    /// The drawing's own size, in the SVG's units.
    public static let size = CGSize(width: 747, height: 731)

    public func path(in rect: CGRect) -> Path {
        // Fitted, not stretched, and centred in whatever it is given.
        let scale = min(rect.width / Self.size.width, rect.height / Self.size.height)
        let origin = CGPoint(x: rect.midX - Self.size.width * scale / 2,
                             y: rect.midY - Self.size.height * scale / 2)
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: origin.x + x * scale, y: origin.y + y * scale)
        }

        var path = Path()
        path.move(to: p(326.889, 27.0854))
        path.addCurve(to: p(419.353, 27.0854), control1: p(347.131, -9.0285), control2: p(399.111, -9.02845))
        path.addLine(to: p(468.09, 114.034))
        path.addCurve(to: p(522.888, 140.422), control1: p(478.989, 133.478), control2: p(500.89, 144.025))
        path.addLine(to: p(621.252, 124.315))
        path.addCurve(to: p(678.903, 196.607), control1: p(662.108, 117.624), control2: p(694.517, 158.264))
        path.addLine(to: p(641.311, 288.921))
        path.addCurve(to: p(654.845, 348.217), control1: p(632.905, 309.566), control2: p(638.313, 333.265))
        path.addLine(to: p(728.768, 415.08))
        path.addCurve(to: p(708.192, 505.226), control1: p(759.472, 442.851), control2: p(747.905, 493.527))
        path.addLine(to: p(612.58, 533.392))
        path.addCurve(to: p(574.659, 580.944), control1: p(591.198, 539.691), control2: p(576.042, 558.696))
        path.addLine(to: p(568.474, 680.427))
        path.addCurve(to: p(485.166, 720.546), control1: p(565.906, 721.748), control2: p(519.073, 744.301))
        path.addLine(to: p(403.531, 663.355))
        path.addCurve(to: p(342.711, 663.355), control1: p(385.275, 650.565), control2: p(360.967, 650.565))
        path.addLine(to: p(261.076, 720.546))
        path.addCurve(to: p(177.767, 680.427), control1: p(227.169, 744.301), control2: p(180.336, 721.748))
        path.addLine(to: p(171.583, 580.944))
        path.addCurve(to: p(133.662, 533.392), control1: p(170.2, 558.696), control2: p(155.044, 539.691))
        path.addLine(to: p(38.0497, 505.226))
        path.addCurve(to: p(17.4735, 415.08), control1: p(-1.66341, 493.527), control2: p(-13.2304, 442.851))
        path.addLine(to: p(91.3973, 348.217))
        path.addCurve(to: p(104.931, 288.921), control1: p(107.929, 333.265), control2: p(113.337, 309.566))
        path.addLine(to: p(67.3387, 196.607))
        path.addCurve(to: p(124.99, 124.315), control1: p(51.7248, 158.264), control2: p(84.1337, 117.624))
        path.addLine(to: p(223.355, 140.422))
        path.addCurve(to: p(278.152, 114.034), control1: p(245.353, 144.024), control2: p(267.253, 133.478))
        path.addLine(to: p(326.889, 27.0854))
        path.closeSubpath()
        guard eyes else { return path }
        path.move(to: p(419.114, 253.578))
        path.addCurve(to: p(374.117, 231.218), control1: p(413.68, 234.385), control2: p(392.921, 224.562))
        path.addCurve(to: p(350.856, 277.731), control1: p(355.314, 237.874), control2: p(345.604, 258.488))
        path.addCurve(to: p(366.799, 370.549), control1: p(359.141, 308.086), control2: p(364.48, 339.17))
        path.addCurve(to: p(404.248, 406.633), control1: p(368.269, 390.442), control2: p(384.301, 406.633))
        path.addCurve(to: p(439.204, 370.541), control1: p(424.195, 406.633), control2: p(440.485, 390.447))
        path.addCurve(to: p(419.114, 253.578), control1: p(436.656, 330.954), control2: p(429.921, 291.747))
        path.closeSubpath()
        path.move(to: p(554.324, 234.055))
        path.addCurve(to: p(509.328, 211.696), control1: p(548.89, 214.863), control2: p(528.131, 205.04))
        path.addCurve(to: p(486.066, 258.208), control1: p(490.524, 218.352), control2: p(480.814, 238.965))
        path.addCurve(to: p(502.01, 351.027), control1: p(494.351, 288.564), control2: p(499.69, 319.647))
        path.addCurve(to: p(539.458, 387.111), control1: p(503.48, 370.919), control2: p(519.511, 387.111))
        path.addCurve(to: p(574.414, 351.019), control1: p(559.405, 387.111), control2: p(575.695, 370.925))
        path.addCurve(to: p(554.324, 234.055), control1: p(571.865, 311.431), control2: p(565.131, 272.224))
        path.closeSubpath()
        return path
    }
}
