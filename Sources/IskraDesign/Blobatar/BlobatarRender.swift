//  The renderer-independent half of the blobatar port. The generator it draws is ported from
//  blobatar (https://blobatar.dev), MIT licence, Copyright (c) 2026 Alain.
//  See Licenses/blobatar.txt.

import CoreGraphics
import Foundation

/// One thing to fill, in the order it is filled in.
///
/// A creature is drawn twice in this app and in two different worlds: on screen, into a SwiftUI
/// `Canvas`, and into a bitmap, for the picture a notification carries — and the second one runs
/// in the notification extension, a process with no screen and no view in it at all. Both go
/// through here, so "the face on the lock screen is the face in the chat list" is a property of
/// there being one list of marks rather than of two draw loops agreeing with each other.
struct BlobatarMark {
    var path: CGPath
    var color: BlobatarOklch
}

extension Blobatar.Figure {
    /// How much larger than its own 100×100 box this creature may be drawn.
    ///
    /// A blobatar does not fill the box it is laid out in: the body's radius is somewhere between
    /// 31 and 38 of a box whose half-width is 50, so a typical creature covers about seventy per
    /// cent of what a photograph covers entirely. Drawn at 1:1 beside a row of real avatars it
    /// therefore reads as *a smaller avatar* rather than as a different kind of one — which is
    /// exactly how it was reported.
    ///
    /// So it grows to fill the space, and the ceiling is clamped per creature rather than applied
    /// flat: the figures vary — a reach of 27 at one end of four thousand seeds and 48 at the
    /// other — and a flat factor generous enough to help the small ones slices the tip off the
    /// large ones. Each grows until it either reaches the ceiling or touches the edge of its box,
    /// whichever comes first, so nothing is ever clipped and no creature's proportions change.
    ///
    /// This is a fact about *drawing*, not about the creature: the marks are untouched, so the
    /// seed still comes out as the same face here as anywhere else blobatar runs. And it is not
    /// used by `BlobatarImage` — a notification draws its creature on a plate, and the plate is
    /// what fills the circle there; growing the figure inside it would crop the plate instead.
    func magnification(upTo ceiling: Double) -> Double {
        var box = CGRect.null
        for mark in marks(scale: 1) { box = box.union(mark.path.boundingBox) }
        guard !box.isNull else { return 1 }

        let reach = max(50 - box.minX, 50 - box.minY, box.maxX - 50, box.maxY - 50)
        guard reach > 0 else { return 1 }

        return min(ceiling, 50 / reach)
    }

    /// Everything to fill, in order, for a creature drawn into a square of `scale × 100` points.
    ///
    /// The order is the order the SVG writes: the plate, then the body — petals, then whatever
    /// the silhouette adds, then the core outline — and the eyes last, on top.
    ///
    /// Each mark is filled on its own rather than unioned into one path. The union is what the
    /// overlap already draws — and a single path would have its subpaths decide by winding
    /// whether they add to the body or punch a hole in it, which is a way for a creature to
    /// arrive with a bite taken out of its side.
    func marks(scale: Double) -> [BlobatarMark] {
        var marks: [BlobatarMark] = []

        if let plate = backdrop {
            marks.append(BlobatarMark(path: plate.cgPath(scale: scale), color: palette.background))
        }

        for petal in layout.petals {
            let r = BlobatarOutline.round2(petal.r) * scale
            let center = CGPoint(
                x: BlobatarOutline.round2(petal.cx) * scale,
                y: BlobatarOutline.round2(petal.cy) * scale
            )
            let box = CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
            marks.append(BlobatarMark(path: CGPath(ellipseIn: box, transform: nil),
                                      color: palette.head))
        }

        for outline in layout.extra {
            marks.append(BlobatarMark(path: outline.cgPath(scale: scale), color: palette.head))
        }
        marks.append(BlobatarMark(path: layout.outline.cgPath(scale: scale), color: palette.head))

        for eye in layout.eyes {
            let outline = BlobatarGeometry.superellipse(
                cx: eye.cx, cy: eye.cy, rx: eye.rx, ry: eye.ry, n: eye.n, rot: eye.rot
            )
            marks.append(BlobatarMark(path: outline.cgPath(scale: scale), color: palette.eye))
        }

        return marks
    }
}
