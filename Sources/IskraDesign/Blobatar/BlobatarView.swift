//  The SwiftUI side of the blobatar port. The generator it draws is ported from blobatar
//  (https://blobatar.dev), MIT licence, Copyright (c) 2026 Alain. See Licenses/blobatar.txt.

import SwiftUI

/// Draws the creature a seed comes out as.
///
/// One `Canvas` and a handful of filled paths — no image decoding, no SVG parsing, no network.
/// Cheap enough to put in every row of a scrolling list, which is exactly where it goes.
public struct BlobatarView: View {
    /// The string the face is computed from. An identifier, not a display name — see `Blobatar`.
    public let seed: String
    public let backdrop: Blobatar.Backdrop

    public init(seed: String, backdrop: Blobatar.Backdrop = .none) {
        self.seed = seed
        self.backdrop = backdrop
    }

    public var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, size in
            let figure = BlobatarCache.shared.figure(for: seed, backdrop: backdrop)
            // The figure is laid out in a 100×100 box; everything below is that box mapped onto
            // whatever the caller gave us.
            let scale = min(size.width, size.height) / 100

            if let plate = figure.backdrop {
                context.fill(
                    plate.path(scale: scale), with: .color(Color(figure.palette.background))
                )
            }

            // Each mark is filled on its own rather than unioned into one path. The union is
            // what the overlap already draws — and a single path would have its subpaths decide
            // by winding whether they add to the body or punch a hole in it, which is a way for
            // a creature to arrive with a bite taken out of its side.
            let head = GraphicsContext.Shading.color(Color(figure.palette.head))
            for petal in figure.layout.petals {
                let r = BlobatarOutline.round2(petal.r) * scale
                let center = CGPoint(
                    x: BlobatarOutline.round2(petal.cx) * scale,
                    y: BlobatarOutline.round2(petal.cy) * scale
                )
                context.fill(
                    Path(ellipseIn: CGRect(
                        x: center.x - r, y: center.y - r, width: r * 2, height: r * 2
                    )),
                    with: head
                )
            }
            for outline in figure.layout.extra {
                context.fill(outline.path(scale: scale), with: head)
            }
            context.fill(figure.layout.outline.path(scale: scale), with: head)

            let eye = GraphicsContext.Shading.color(Color(figure.palette.eye))
            for e in figure.layout.eyes {
                let outline = BlobatarGeometry.superellipse(
                    cx: e.cx, cy: e.cy, rx: e.rx, ry: e.ry, n: e.n, rot: e.rot
                )
                context.fill(outline.path(scale: scale), with: eye)
            }
        }
        .accessibilityHidden(true)
    }
}

/// The creatures already worked out.
///
/// A blobatar costs a hash and some trigonometry, which is nothing — until a chat list redraws
/// forty rows a frame while it scrolls and every one of them recomputes the same face. Bounded,
/// because a long-lived session sees a lot of senders and this is a convenience, not a store.
@MainActor
final class BlobatarCache {
    static let shared = BlobatarCache()

    private var figures: [String: Blobatar.Figure] = [:]
    private var order: [String] = []
    private let limit = 512

    func figure(for seed: String, backdrop: Blobatar.Backdrop) -> Blobatar.Figure {
        let key = "\(backdrop)\u{0}\(seed)"
        if let cached = figures[key] { return cached }

        let figure = Blobatar.figure(
            for: seed, options: Blobatar.Options(backdrop: backdrop)
        )
        figures[key] = figure
        order.append(key)
        if order.count > limit {
            figures.removeValue(forKey: order.removeFirst())
        }
        return figure
    }
}
