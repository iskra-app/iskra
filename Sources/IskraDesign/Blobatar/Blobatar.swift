//  Ported from blobatar (https://blobatar.dev), MIT licence,
//  Copyright (c) 2026 Alain. See Licenses/blobatar.txt.

import Foundation

/// A creature drawn from a string.
///
/// The same seed always produces the same face, on every device, with no network and no state —
/// which is the whole reason this is a port rather than a call to `blobatar.dev/avatar/<seed>`.
/// That endpoint would work perfectly and would also mean sending the list of everyone you talk
/// to a third party, once per row of the chat list. The arithmetic is three hundred lines; the
/// privacy cost of not doing it is permanent.
///
/// Seed it with an *identifier*, never with a display name. A name is something people change,
/// and a face that changes when somebody edits their profile is not an identity.
public struct Blobatar {
    /// The plate behind the creature. Off by default — the body is the blobatar.
    public enum Backdrop {
        case none
        case square
        case circle
        case squircle
    }

    public struct Options {
        /// Emits `width`/`height` on the SVG. The `viewBox` scales either way.
        public var size: Int?
        public var backdrop: Backdrop
        /// Locks the hue in degrees, so the seed drives shape alone.
        public var hue: Double?
        /// Locks the tone, a position in `[0, 1)` across the six swatches.
        public var tone: Double?
        /// NFC, trim and lowercase the seed before hashing.
        public var normalize: Bool
        /// Enforce the minimum contrast ratios.
        public var contrast: Bool
        /// A `<title>`, for screen readers reading the SVG.
        public var title: String?
        /// Fixed trait positions, keyed exactly as the layout reads them — `["shape": [0.96]]`.
        /// A list is "any of these, whichever this seed comes out as".
        public var traits: [String: [Double]]

        public init(
            size: Int? = nil,
            backdrop: Backdrop = .none,
            hue: Double? = nil,
            tone: Double? = nil,
            normalize: Bool = true,
            contrast: Bool = true,
            title: String? = nil,
            traits: [String: [Double]] = [:]
        ) {
            self.size = size
            self.backdrop = backdrop
            self.hue = hue
            self.tone = tone
            self.normalize = normalize
            self.contrast = contrast
            self.title = title
            self.traits = traits
        }
    }

    /// Everything needed to draw one creature, in the 100×100 space it is laid out in.
    public struct Figure {
        /// The silhouette's name — "round", "droplet", "triangle". Useful for tests and for
        /// nothing else; nobody is shown this word.
        public var shape: String
        var layout: BlobatarLayout
        var palette: BlobatarPalette
        var backdrop: BlobatarOutline?
    }

    /// Lays out the creature for `seed`.
    public static func figure(for seed: String, options: Options = Options()) -> Figure {
        let traits = BlobatarTraits(
            seed: seed, normalize: options.normalize, overrides: options.traits
        )
        let layout = BlobatarLayout.make(traits)
        let palette = BlobatarPalette(
            hue: options.hue ?? traits.num("hue", 0, 360),
            tone: options.tone ?? traits("tone"),
            enforce: options.contrast
        )
        return Figure(
            shape: layout.shape,
            layout: layout,
            palette: palette,
            backdrop: plate(for: options.backdrop)
        )
    }

    private static func plate(for backdrop: Backdrop) -> BlobatarOutline? {
        switch backdrop {
        case .none:
            return nil
        case .square:
            return BlobatarOutline(commands: [
                .move(0, 0), .horizontal(100), .vertical(100), .horizontal(0), .close,
            ])
        case .circle, .squircle:
            return BlobatarGeometry.superellipse(
                cx: 50, cy: 50, rx: 50, ry: 50, n: backdrop == .circle ? 2 : 6
            )
        }
    }

    /// The figure as SVG markup, byte for byte what blobatar itself emits.
    ///
    /// Nothing in the app renders this — SwiftUI draws the paths directly. It exists so the
    /// golden fixture can be compared against, which is the only way "this is the same program"
    /// is a claim rather than an impression.
    static func svg(for seed: String, options: Options = Options()) -> String {
        let figure = figure(for: seed, options: options)
        let layout = figure.layout
        let format = BlobatarOutline.format

        let dimensions = options.size.map { " width=\"\($0)\" height=\"\($0)\"" } ?? ""
        let title = options.title.map { "<title>\(escape($0))</title>" } ?? ""
        let plate = figure.backdrop.map {
            "<path d=\"\($0.pathData)\" fill=\"\(BlobatarPalette.hex(figure.palette.background))\"/>"
        } ?? ""

        let petals = layout.petals.map {
            "<circle cx=\"\(format($0.cx))\" cy=\"\(format($0.cy))\" r=\"\(format($0.r))\"/>"
        }.joined()
        let extra = layout.extra.map { "<path d=\"\($0.pathData)\"/>" }.joined()
        let eyes = layout.eyes.map { eye in
            let outline = BlobatarGeometry.superellipse(
                cx: eye.cx, cy: eye.cy, rx: eye.rx, ry: eye.ry, n: eye.n, rot: eye.rot
            )
            return "<path d=\"\(outline.pathData)\"/>"
        }.joined()

        let body = "<g fill=\"\(BlobatarPalette.hex(figure.palette.head))\">"
            + petals + extra + "<path d=\"\(layout.outline.pathData)\"/></g>"
            + "<g fill=\"\(BlobatarPalette.hex(figure.palette.eye))\">" + eyes + "</g>"

        return "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 100 100\""
            + dimensions + ">" + title + plate + body + "</svg>"
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
