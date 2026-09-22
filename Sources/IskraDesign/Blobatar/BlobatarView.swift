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

    /// How much of the space it is given a creature is allowed to grow into.
    ///
    /// A blobatar is laid out well inside its box, so at 1:1 it sits in the middle of an avatar
    /// circle looking like a smaller avatar rather than a different kind of one. A sixth again
    /// is the number that puts it beside a photograph without making it the loudest thing in a
    /// list of faces — and it is a ceiling, not a factor: see `Figure.magnification(upTo:)`,
    /// which stops any one creature short of it rather than letting it touch the edge.
    static let fill = 1.16

    public var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, size in
            let drawing = BlobatarCache.shared.drawing(for: seed, backdrop: backdrop)
            let side = min(size.width, size.height)

            // The figure is laid out in a 100×100 box; the marks below are that box mapped onto
            // whatever the caller gave us — and they are the same marks the notification
            // extension rasterizes, which is what keeps one seed one face everywhere.
            //
            // Mapped a little larger than the box, and then pulled back by half of what it grew
            // by, so the creature grows out of its own middle instead of out of its top left
            // corner. The marks themselves are untouched: this is the size the face is drawn at,
            // not a change to the face.
            let grown = side * drawing.magnification
            context.translateBy(x: (size.width - grown) / 2, y: (size.height - grown) / 2)

            for mark in drawing.figure.marks(scale: grown / 100) {
                context.fill(Path(mark.path), with: .color(Color(mark.color)))
            }
        }
        .accessibilityHidden(true)
    }
}

/// A creature and the size it is drawn at — worked out once, together, because the second is
/// measured from the first. See `Figure.magnification(upTo:)`.
struct BlobatarDrawing {
    var figure: Blobatar.Figure
    var magnification: Double
}

/// The creatures already worked out.
///
/// A blobatar costs a hash and some trigonometry, which is nothing — until a chat list redraws
/// forty rows a frame while it scrolls and every one of them recomputes the same face. Bounded,
/// because a long-lived session sees a lot of senders and this is a convenience, not a store.
@MainActor
final class BlobatarCache {
    static let shared = BlobatarCache()

    private var drawings: [String: BlobatarDrawing] = [:]
    private var order: [String] = []
    private let limit = 512

    /// The creature and the size it is drawn at. Both are cached, and the second is the reason
    /// this is worth caching at all now: measuring how far a figure reaches means walking every
    /// path in it, which is cheap once and wasteful forty times a frame.
    func drawing(for seed: String, backdrop: Blobatar.Backdrop) -> BlobatarDrawing {
        let key = "\(backdrop)\u{0}\(seed)"
        if let cached = drawings[key] { return cached }

        let figure = Blobatar.figure(
            for: seed, options: Blobatar.Options(backdrop: backdrop)
        )
        // A plate fills the box by itself, so a creature drawn on one is already the size of the
        // circle around it and must not be grown into its own backdrop.
        let drawing = BlobatarDrawing(
            figure: figure,
            magnification: backdrop == .none ? figure.magnification(upTo: BlobatarView.fill) : 1
        )
        drawings[key] = drawing
        order.append(key)
        if order.count > limit {
            drawings.removeValue(forKey: order.removeFirst())
        }
        return drawing
    }
}
