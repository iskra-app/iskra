//  Ported from blobatar (https://blobatar.dev), MIT licence,
//  Copyright (c) 2026 Alain. See Licenses/blobatar.txt.

import Foundation
import SwiftUI

/// A colour in OKLCh — lightness, chroma, hue.
///
/// The palette is authored here rather than in sRGB because the guarantee it has to keep is
/// perceptual: an eye must stay readable against its own body at every hue the seed can land on.
/// Walking lightness in OKLCh moves what a person sees; walking it in HSL does not.
struct BlobatarOklch: Equatable {
    var l: Double
    var c: Double
    var h: Double
}

/// The three colours a blobatar has, already resolved.
struct BlobatarPalette {
    /// The backdrop. Drawn only when one is asked for — by default the creature sits directly on
    /// whatever is behind it.
    var background: BlobatarOklch
    /// The body, and everything drawn in the body's fill.
    var head: BlobatarOklch
    /// The eyes.
    var eye: BlobatarOklch

    /// The authored ramp: the seed picks a hue and a tone, and the rest follows.
    ///
    /// - Parameters:
    ///   - hue: degrees.
    ///   - tone: position in `[0, 1)` across the six frozen swatches.
    ///   - enforce: whether the contrast floors are applied. Off only for tests.
    init(hue: Double, tone: Double, enforce: Bool = true) {
        let swatch = Self.tone(at: tone)
        var head = Self.ensureContrast(
            BlobatarOklch(l: swatch.l, c: swatch.c, h: hue), on: Self.darkSurface,
            atLeast: Self.surfaceFloor
        )
        let background = BlobatarOklch(l: 0.965, c: 0.01, h: hue)
        // Polarity follows the body: dark eyes on a light creature, light eyes on a dark one.
        // Without it the ink swatch renders a face nobody can see.
        var eye = head.l >= 0.5
            ? BlobatarOklch(l: 0.17, c: 0.02, h: hue)
            : BlobatarOklch(l: 0.97, c: 0.012, h: hue)

        if enforce {
            // In order, because the second pair resolves against the first pair's answer. The
            // body/backdrop floor is deliberately weak — the backdrop is usually off, and the
            // pale swatches are meant to sit quietly. 4.5 on the eyes is the WCAG text floor:
            // they are small marks that have to read at 24 points.
            head = Self.ensureContrast(head, on: background, atLeast: 1.25)
            eye = Self.ensureContrast(eye, on: head, atLeast: 4.5)
        }

        self.background = background
        self.head = head
        self.eye = eye
    }

    // MARK: - The tone set

    /// Six swatches, as cumulative upper edges. Lightness and chroma come from here; hue is the
    /// only colour axis the seed drives directly.
    private static let tones: [(edge: Double, l: Double, c: Double)] = [
        (0.2, 0.86, 0.085),   // pastel
        (0.36, 0.9, 0.028),   // pale neutral
        (0.62, 0.73, 0.135),  // mid
        (0.8, 0.62, 0.165),   // deep
        (0.93, 0.87, 0.16),   // bright
        // Dark, but never darker than a dark host surface: at l 0.17 this swatch scored 1.03:1
        // against a near-black page and the body simply vanished, leaving two eyes floating.
        (1.0, 0.34, 0.035),   // ink
    ]

    private static func tone(at value: Double) -> (l: Double, c: Double) {
        let found = tones.first { value < $0.edge } ?? tones[0]
        return (found.l, found.c)
    }

    /// The darkest surface a backdrop-less creature is expected to land on, and the ratio it has
    /// to clear against it. The palette's own `background` says nothing about this case, because
    /// by default it is never drawn.
    private static let darkSurface = BlobatarOklch(l: 0.145, c: 0, h: 0)
    private static let surfaceFloor = 1.5

    // MARK: - Contrast

    /// Nudges lightness until the pair clears `minimum`, leaning the way it already leans.
    static func ensureContrast(
        _ foreground: BlobatarOklch, on background: BlobatarOklch, atLeast minimum: Double
    ) -> BlobatarOklch {
        if contrast(foreground, background) >= minimum { return foreground }

        let lean: Double = foreground.l >= background.l ? 1 : -1
        for direction in [lean, -lean] {
            var probe = foreground
            for _ in 0..<60 {
                probe.l = Swift.min(1, Swift.max(0, probe.l + direction * 0.02))
                if contrast(probe, background) >= minimum { return probe }
                if probe.l == 0 || probe.l == 1 { break }
            }
        }

        // Unreachable for the authored ramp, but reachable for an overridden one.
        let black = BlobatarOklch(l: 0, c: 0, h: foreground.h)
        let white = BlobatarOklch(l: 1, c: 0, h: foreground.h)
        return contrast(black, background) >= contrast(white, background) ? black : white
    }

    static func contrast(_ a: BlobatarOklch, _ b: BlobatarOklch) -> Double {
        let x = luminance(a)
        let y = luminance(b)
        return (Swift.max(x, y) + 0.05) / (Swift.min(x, y) + 0.05)
    }

    private static func luminance(_ color: BlobatarOklch) -> Double {
        let (r, g, b) = resolve(color)
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    // MARK: - Out of OKLCh

    /// OKLCh to linear-light sRGB. Components may fall outside `[0, 1]` — that is what "out of
    /// gamut" means here.
    private static func toLinear(_ color: BlobatarOklch) -> (Double, Double, Double) {
        let radians = color.h * Double.pi / 180
        let a = color.c * cos(radians)
        let b = color.c * sin(radians)

        let l_ = color.l + 0.3963377774 * a + 0.2158037573 * b
        let m_ = color.l - 0.1055613458 * a - 0.0638541728 * b
        let s_ = color.l - 0.0894841775 * a - 1.291485548 * b

        let L = l_ * l_ * l_
        let M = m_ * m_ * m_
        let S = s_ * s_ * s_

        return (
            4.0767416621 * L - 3.3077115913 * M + 0.2309699292 * S,
            -1.2684380046 * L + 2.6097574011 * M - 0.3413193965 * S,
            -0.0041960863 * L - 0.7034186147 * M + 1.707614701 * S
        )
    }

    private static func inGamut(_ rgb: (Double, Double, Double)) -> Bool {
        [rgb.0, rgb.1, rgb.2].allSatisfy { $0 >= -1e-4 && $0 <= 1 + 1e-4 }
    }

    /// Brings a colour into gamut by **binary-searching chroma down**, never by clipping the
    /// channels. Clipping shifts hue, and a body that changes colour as it saturates is a body
    /// whose seed no longer means what it said.
    private static func resolve(_ color: BlobatarOklch) -> (Double, Double, Double) {
        var rgb = toLinear(color)
        if !inGamut(rgb) {
            var lo = 0.0
            var hi = color.c
            for _ in 0..<12 {
                let mid = (lo + hi) / 2
                if inGamut(toLinear(BlobatarOklch(l: color.l, c: mid, h: color.h))) {
                    lo = mid
                } else {
                    hi = mid
                }
            }
            rgb = toLinear(BlobatarOklch(l: color.l, c: lo, h: color.h))
        }
        let clamp = { (v: Double) in Swift.min(1, Swift.max(0, v)) }
        return (clamp(rgb.0), clamp(rgb.1), clamp(rgb.2))
    }

    /// The sRGB components, transfer function applied — what `#rrggbb` quantizes.
    static func components(_ color: BlobatarOklch) -> (Double, Double, Double) {
        let (r, g, b) = resolve(color)
        let encode = { (v: Double) in
            v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055
        }
        return (encode(r), encode(g), encode(b))
    }

    /// `#rrggbb`, exactly as blobatar writes it — which is what the golden fixture compares.
    static func hex(_ color: BlobatarOklch) -> String {
        let (r, g, b) = components(color)
        return "#" + [r, g, b].map { component in
            // JavaScript's rounding, not Swift's: ties go toward +∞.
            let byte = Int((component * 255 + 0.5).rounded(.down))
            return String(format: "%02x", byte)
        }.joined()
    }
}

extension Color {
    /// A palette colour, as SwiftUI sees it.
    init(_ color: BlobatarOklch) {
        let (r, g, b) = BlobatarPalette.components(color)
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }
}
