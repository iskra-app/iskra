//  Ported from blobatar (https://blobatar.dev), MIT licence,
//  Copyright (c) 2026 Alain. See Licenses/blobatar.txt.

import Foundation

/// The five path primitives every silhouette is traced with.
///
/// Nothing here is an asset. A blobatar is not picked out of a set of drawn blobs — it is
/// computed, which is why ten silhouettes and a continuous seed cost a few hundred lines and no
/// bytes at all in the bundle.
enum BlobatarGeometry {
    /// `|x/a|^n + |y/b|^n = 1`, as four cubic Béziers — one per quadrant.
    ///
    /// The one shape that covers most of the vocabulary: `n = 2` is an ellipse (both eyes, the
    /// round body, the circular backdrop), `n ≈ 4` a squircle, and a large `n` a rectangle. So
    /// "how square is this creature" is a number the seed picks rather than a set of alternative
    /// drawings someone had to make.
    ///
    /// The control offset is derived rather than guessed: it is what makes the curve pass exactly
    /// through the superellipse's 45° point. At `n = 2` it comes out as 0.5523, the standard
    /// circle constant, which is the sign that the derivation is right.
    static func superellipse(
        cx: Double, cy: Double, rx: Double, ry: Double, n: Double = 4, rot: Double = 0
    ) -> BlobatarOutline {
        // Past n ≈ 5.55 the offset would exceed the radius and the curve would bulge *outside*
        // its own bounding box — an inflated corner instead of a sharper one. Clamping trades
        // exactness at the 45° point for a shape that always stays inside its stated bounds.
        let k = Swift.min(1, (8 * pow(2, -1 / n) - 4) / 3)
        let ak = rx * k
        let bk = ry * k

        // Anchor, control, control — walking the four quadrants.
        let points: [(Double, Double)] = [
            (rx, 0),
            (rx, bk), (ak, ry), (0, ry),
            (-ak, ry), (-rx, bk), (-rx, 0),
            (-rx, -bk), (-ak, -ry), (0, -ry),
            (ak, -ry), (rx, -bk), (rx, 0),
        ]

        let t = rot * Double.pi / 180
        let cosine = cos(t)
        let sine = sin(t)
        func at(_ i: Int) -> (Double, Double) {
            let (x, y) = points[i]
            return (cx + x * cosine - y * sine, cy + x * sine + y * cosine)
        }

        var commands: [BlobatarCommand] = [.move(at(0).0, at(0).1)]
        for i in stride(from: 1, to: 13, by: 3) {
            let c1 = at(i), c2 = at(i + 1), end = at(i + 2)
            commands.append(.cubic(c1.0, c1.1, c2.0, c2.1, end.0, end.1))
        }
        commands.append(.close)
        return BlobatarOutline(commands: commands)
    }

    /// A closed Catmull-Rom spline through radii sampled around a circle.
    ///
    /// This is everything that has to look hand-drawn. The radii are multipliers of the base
    /// radius, one per vertex, so a seed nudging them by ±16% produces lopsided pebble shapes
    /// with no noise function anywhere — the vertex count alone decides how lumpy it gets.
    ///
    /// Catmull-Rom rather than a fitted Bézier because it passes exactly through its points, so
    /// the radii mean what they say and the eye-containment arithmetic downstream stays honest.
    static func blob(
        cx: Double, cy: Double, rx: Double, ry: Double, radii: [Double], rot: Double = 0
    ) -> BlobatarOutline {
        let n = radii.count
        let t0 = rot * Double.pi / 180
        let points: [(Double, Double)] = radii.enumerated().map { index, m in
            let a = t0 + 2 * Double.pi * Double(index) / Double(n)
            return (cx + rx * m * cos(a), cy + ry * m * sin(a))
        }
        func at(_ i: Int) -> (Double, Double) { points[((i % n) + n) % n] }

        var commands: [BlobatarCommand] = [.move(at(0).0, at(0).1)]
        for i in 0..<n {
            let (x0, y0) = at(i - 1)
            let (x1, y1) = at(i)
            let (x2, y2) = at(i + 1)
            let (x3, y3) = at(i + 2)
            commands.append(.cubic(
                x1 + (x2 - x0) / 6, y1 + (y2 - y0) / 6,
                x2 - (x3 - x1) / 6, y2 - (y3 - y1) / 6,
                x2, y2
            ))
        }
        commands.append(.close)
        return BlobatarOutline(commands: commands)
    }

    /// A regular polygon with rounded corners.
    ///
    /// Here because neither of the other two reaches a flat-sided shape: a superellipse has no
    /// odd-sided member at all, and a Catmull-Rom spline rounds a corner *away* rather than
    /// turning it. Each corner is cut back along both of its edges and joined with a quadratic
    /// through the vertex, which keeps the whole outline inside the polygon's hull for free — a
    /// quadratic never leaves the triangle of its three points.
    static func polygon(
        cx: Double, cy: Double, rx: Double, ry: Double,
        sides: Int, round: Double = 0.3, rot: Double = 0
    ) -> BlobatarOutline {
        // Halved because the cut is taken from both ends of every edge: at 1 each end reaches the
        // midpoint and they meet exactly, and anything past that would fold the outline back on
        // itself.
        let k = round > 0 ? (round < 1 ? round / 2 : 0.5) : 0
        // −90° so a vertex sits at the top: a triangle points up and rests on a flat edge, which
        // is the orientation anybody who asks for a triangle means.
        let t0 = rot * Double.pi / 180 - Double.pi / 2
        let vertices: [(Double, Double)] = (0..<sides).map { i in
            let a = t0 + 2 * Double.pi * Double(i) / Double(sides)
            return (cx + rx * cos(a), cy + ry * sin(a))
        }
        func at(_ i: Int) -> (Double, Double) { vertices[((i % sides) + sides) % sides] }
        /// The cut point on the edge leaving vertex `i` toward vertex `j`.
        func cut(_ i: Int, _ j: Int) -> (Double, Double) {
            let (x0, y0) = at(i)
            let (x1, y1) = at(j)
            return (x0 + (x1 - x0) * k, y0 + (y1 - y0) * k)
        }

        let start = cut(0, -1)
        var commands: [BlobatarCommand] = [.move(start.0, start.1)]
        for i in 0..<sides {
            let (x, y) = at(i)
            let out = cut(i, i + 1)
            commands.append(.quadratic(x, y, out.0, out.1))
            // The straight run to the next corner's cut, omitted when the cuts already meet — so
            // a fully rounded polygon does not emit a zero-length line per side.
            if k < 0.5 {
                let next = cut(i + 1, i)
                commands.append(.line(next.0, next.1))
            }
        }
        commands.append(.close)
        return BlobatarOutline(commands: commands)
    }

    /// The straight run of a capsule, as a plain box.
    ///
    /// Drawn together with the two cap circles the capsule decorates itself with, the union is an
    /// exact stadium: the box reaches full height everywhere, so each cap meets it along its own
    /// diameter and there is no crease. A superellipse cannot stand in — its corners round by a
    /// fraction of the whole radius, so it pinches away from the caps and the join shows.
    static func box(cx: Double, cy: Double, rx: Double, ry: Double) -> BlobatarOutline {
        BlobatarOutline(commands: [
            .move(cx - rx, cy - ry),
            .horizontal(cx + rx),
            .vertical(cy + ry),
            .horizontal(cx - rx),
            .close,
        ])
    }

    /// The taper of a droplet: the two tangents from an apex to the body ellipse.
    ///
    /// Drawn with that ellipse, the union is a teardrop. A tangent meets the curve without a
    /// corner, so the point grows out of the head instead of being stuck onto it — which is why
    /// this takes the body's own radii rather than drawing a cone of its own.
    static func taper(
        cx: Double, cy: Double, rx: Double, ry: Double, tip: Double
    ) -> BlobatarOutline {
        // In the circle this ellipse is an affine image of, the tangent points sit at angle
        // acos(1/tip) from the apex direction. An affine map preserves tangency, so scaling those
        // two points by rx and ry is exact rather than an approximation.
        let t = Swift.max(1.05, tip)
        let tx = rx * (1 - 1 / (t * t)).squareRoot()
        let ty = cy - ry / t
        let apex = cy - t * ry
        // How far up each flank the eased point takes over. Small, so the flanks stay straight
        // enough to read as a taper — and so the drawn tip stops just short of the apex, which is
        // what keeps it from becoming a needle at 28 points.
        let px = tx * 0.14
        let py = ty + 0.86 * (apex - ty)
        return BlobatarOutline(commands: [
            .move(cx - tx, ty),
            .line(cx - px, py),
            .quadratic(cx, apex, cx + px, py),
            .line(cx + tx, ty),
            .close,
        ])
    }
}
