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
