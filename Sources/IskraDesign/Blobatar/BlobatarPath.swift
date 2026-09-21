//  Ported from blobatar (https://blobatar.dev), MIT licence,
//  Copyright (c) 2026 Alain. See Licenses/blobatar.txt.

import Foundation
import SwiftUI

/// One drawing command, in the 100×100 space every blobatar is laid out in.
///
/// The figure is kept as commands rather than as a `Path` or as an SVG string because it has to
/// become *both*. SwiftUI draws the `Path`; the tests serialize the SVG and compare it against
/// blobatar's own golden fixture, byte for byte. Two renderers over one command list is what
/// makes "this port is the same program" a thing a test can assert rather than a thing a
/// screenshot suggests.
enum BlobatarCommand {
    case move(Double, Double)
    case cubic(Double, Double, Double, Double, Double, Double)
    case quadratic(Double, Double, Double, Double)
    case line(Double, Double)
    case horizontal(Double)
    case vertical(Double)
    case close
}

/// A traced outline: the commands, and the two ways out of them.
struct BlobatarOutline {
    var commands: [BlobatarCommand]

    /// Rounds to two decimals the way JavaScript's `Math.round` does — ties toward `+∞`, not away
    /// from zero. The difference shows up only at exact halves and only on negative numbers,
    /// which is precisely the sort of thing that would put a single glyph of drift into an
    /// otherwise identical file and cost an afternoon to find.
    static func round2(_ value: Double) -> Double {
        Double(hundredths(value)) / 100
    }

    private static func hundredths(_ value: Double) -> Int {
        Int((value * 100 + 0.5).rounded(.down))
    }

    /// Formats a number the way `String(n)` does in JavaScript, for a value already quantized to
    /// two decimals: no trailing zeros, no exponent, and `-0` written as `0`. Built back out of
    /// the integer hundredths rather than out of a format string, so there is no second rounding
    /// to disagree with the first.
    static func format(_ value: Double) -> String {
        let n = hundredths(value)
        if n == 0 { return "0" }
        let sign = n < 0 ? "-" : ""
        let magnitude = abs(n)
        let whole = magnitude / 100
        let frac = magnitude % 100
        if frac == 0 { return "\(sign)\(whole)" }
        if frac % 10 == 0 { return "\(sign)\(whole).\(frac / 10)" }
        return "\(sign)\(whole)." + (frac < 10 ? "0\(frac)" : "\(frac)")
    }

    /// The `d` attribute. Each command is its letter followed by its numbers, single-spaced, and
    /// commands run together with no separator between them — which is what blobatar emits.
    var pathData: String {
        var d = ""
        for command in commands {
            switch command {
            case let .move(x, y):
                d += "M" + Self.format(x) + " " + Self.format(y)
            case let .cubic(x1, y1, x2, y2, x, y):
                d += "C" + [x1, y1].map(Self.format).joined(separator: " ")
                    + " " + [x2, y2].map(Self.format).joined(separator: " ")
                    + " " + [x, y].map(Self.format).joined(separator: " ")
            case let .quadratic(cx, cy, x, y):
                d += "Q" + [cx, cy].map(Self.format).joined(separator: " ")
                    + " " + [x, y].map(Self.format).joined(separator: " ")
            case let .line(x, y):
                d += "L" + Self.format(x) + " " + Self.format(y)
            case let .horizontal(x):
                d += "H" + Self.format(x)
            case let .vertical(y):
                d += "V" + Self.format(y)
            case .close:
                d += "Z"
            }
        }
        return d
    }

    /// The same outline as a `CGPath`, on the same rounded numbers the SVG carries, so what is
    /// drawn and what is asserted cannot drift apart.
    ///
    /// Core Graphics rather than SwiftUI because this is also what the notification extension
    /// draws with, and that process has no view in it — see `BlobatarImage`.
    func cgPath(scale: Double) -> CGPath {
        let path = CGMutablePath()
        let p = { (x: Double, y: Double) in
            CGPoint(x: Self.round2(x) * scale, y: Self.round2(y) * scale)
        }
        var pen = CGPoint.zero
        for command in commands {
            switch command {
            case let .move(x, y):
                pen = p(x, y)
                path.move(to: pen)
            case let .cubic(x1, y1, x2, y2, x, y):
                pen = p(x, y)
                path.addCurve(to: pen, control1: p(x1, y1), control2: p(x2, y2))
            case let .quadratic(cx, cy, x, y):
                pen = p(x, y)
                path.addQuadCurve(to: pen, control: p(cx, cy))
            case let .line(x, y):
                pen = p(x, y)
                path.addLine(to: pen)
            case let .horizontal(x):
                pen = CGPoint(x: Self.round2(x) * scale, y: pen.y)
                path.addLine(to: pen)
            case let .vertical(y):
                pen = CGPoint(x: pen.x, y: Self.round2(y) * scale)
                path.addLine(to: pen)
            case .close:
                path.closeSubpath()
            }
        }
        return path
    }

    /// The outline SwiftUI draws — the same path, wrapped. Wrapped rather than traced a second
    /// time: two loops over the same commands is exactly the kind of duplication that stays
    /// identical until somebody fixes a rounding bug in one of them.
    func path(scale: Double) -> Path {
        Path(cgPath(scale: scale))
    }
}
