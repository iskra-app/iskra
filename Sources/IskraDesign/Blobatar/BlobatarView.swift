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
            // The figure is laid out in a 100×100 box; the marks below are that box mapped onto
            // whatever the caller gave us — and they are the same marks the notification
            // extension rasterizes, which is what keeps one seed one face everywhere.
            for mark in figure.marks(scale: min(size.width, size.height) / 100) {
                context.fill(Path(mark.path), with: .color(Color(mark.color)))
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
