import SwiftUI

/// Where each picture of an album goes: Telegram's mosaic, worked out from nothing but the
/// pictures' proportions.
///
/// Telegram's code was read, not copied — it is GPL — and what is taken from it is the idea: an
/// album is never a grid of equal squares, which crops every photo into the same shape and makes a
/// panorama and a portrait look alike. It is *rows*, and every row is as tall as it has to be for
/// its pictures to fit the width uncropped; the only freedom is how the pictures are split between
/// rows. So every split is tried, and the one kept is the one closest to a pleasant overall shape —
/// about as tall as it is wide — without a row so thin that its pictures turn into slits, and with
/// the bigger pictures first, the way people expect the first photo of a set to be the important
/// one. A tall first photo beside two or three others gets a column of its own, which no split
/// into rows can give it.
///
/// Pure geometry, so that it can be tested without drawing anything — see `AlbumMosaicTests`.
public enum AlbumMosaic {
    /// `ratios` are width over height, one per picture, in order. Returns one frame per picture, in
    /// a box `width` wide and as tall as the tallest frame's bottom edge.
    public static func frames(ratios: [CGFloat], width: CGFloat, spacing: CGFloat,
                              maxHeight: CGFloat) -> [CGRect] {
        guard !ratios.isEmpty, width > 0 else { return [] }
        // A photo of a receipt or a panorama would otherwise take its row with it — a slit a
        // hundred points wide, or a row as tall as the screen.
        let ratios = ratios.map { min(max($0.isFinite && $0 > 0 ? $0 : 1, 0.5), 2.5) }

        if ratios.count == 1 {
            let height = min(width / ratios[0], maxHeight)
            return [CGRect(x: 0, y: 0, width: width, height: height)]
        }

        var best: (score: CGFloat, frames: [CGRect])?
        func consider(_ frames: [CGRect], penalty: CGFloat) {
            let height = frames.map(\.maxY).max() ?? 0
            let score = abs(height - width * idealShape) / width + penalty
            if best == nil || score < best!.score { best = (score, frames) }
        }

        for split in splits(of: ratios.count) {
            consider(rows(split, ratios: ratios, width: width, spacing: spacing),
                     penalty: penalty(for: split, ratios: ratios, width: width, spacing: spacing))
        }
        if (2...4).contains(ratios.count), ratios[0] < 0.8,
           let column = column(ratios: ratios, width: width, spacing: spacing) {
            consider(column, penalty: 0)
        }

        return fitted(best?.frames ?? [], into: maxHeight)
    }

    /// Height over width of the album the splits are scored against.
    private static let idealShape: CGFloat = 1

    /// The most pictures a row takes.
    private static let rowLimit = 4

    /// Every way of cutting `count` pictures, in order, into rows of one to `rowLimit`.
    static func splits(of count: Int) -> [[Int]] {
        guard count > 0 else { return [[]] }
        var result: [[Int]] = []
        for first in 1...min(rowLimit, count) {
            for rest in splits(of: count - first) {
                result.append([first] + rest)
            }
        }
        return result
    }

    private static func heights(_ split: [Int], ratios: [CGFloat], width: CGFloat, spacing: CGFloat) -> [CGFloat] {
        var start = 0
        return split.map { count in
            defer { start += count }
            let sum = ratios[start..<start + count].reduce(0, +)
            return (width - spacing * CGFloat(count - 1)) / sum
        }
    }

    private static func rows(_ split: [Int], ratios: [CGFloat], width: CGFloat, spacing: CGFloat) -> [CGRect] {
        let heights = heights(split, ratios: ratios, width: width, spacing: spacing)
        var frames: [CGRect] = []
        var y: CGFloat = 0
        var start = 0
        for (row, count) in split.enumerated() {
            let height = heights[row]
            var x: CGFloat = 0
            for index in start..<start + count {
                // The last in a row takes whatever the rounding left, so the right edge is straight.
                let tileWidth = index == start + count - 1 ? width - x : ratios[index] * height
                frames.append(CGRect(x: x, y: y, width: tileWidth, height: height))
                x += tileWidth + spacing
            }
            y += height + spacing
            start += count
        }
        return frames
    }

    /// What makes a split worse than its overall shape says: a row thin enough to read as a strip,
    /// and a row with *more* pictures than the one under it — the first photos of a set are the
    /// ones meant to be looked at, and they should be the big ones.
    private static func penalty(for split: [Int], ratios: [CGFloat], width: CGFloat, spacing: CGFloat) -> CGFloat {
        let heights = heights(split, ratios: ratios, width: width, spacing: spacing)
        var penalty: CGFloat = 0
        for height in heights where height < width / 4 { penalty += 1 }
        for (upper, lower) in zip(split, split.dropFirst()) where upper > lower { penalty += 0.2 }
        // A lone picture below the first row is a picture pulled out of the set. On top it is the
        // set's cover, which is the point of putting a wide first photo there.
        if ratios.count > 2 { penalty += 0.1 * CGFloat(split.dropFirst().filter { $0 == 1 }.count) }
        return penalty
    }

    /// The first picture down the left, the rest stacked beside it — for a tall first photo.
    private static func column(ratios: [CGFloat], width: CGFloat, spacing: CGFloat) -> [CGRect]? {
        let rest = ratios.dropFirst()
        let inverse = rest.map { 1 / $0 }.reduce(0, +)
        let stacked = spacing * CGFloat(rest.count - 1)
        // The left width at which the column and the stack come out the same height.
        var left = ((width - spacing) * inverse + stacked) / (1 / ratios[0] + inverse)
        left = min(max(left, width * 0.4), width * 0.75)
        let right = width - spacing - left
        let height = left / ratios[0]

        // The stack shares the column's height in proportion to what each picture would like.
        let wanted = rest.map { right / $0 }
        let scale = (height - stacked) / wanted.reduce(0, +)
        guard scale > 0 else { return nil }

        var frames = [CGRect(x: 0, y: 0, width: left, height: height)]
        var y: CGFloat = 0
        for (index, want) in wanted.enumerated() {
            let tile = index == wanted.count - 1 ? height - y : want * scale
            frames.append(CGRect(x: left + spacing, y: y, width: right, height: tile))
            y += tile + spacing
        }
        return frames
    }

    /// Squeezed to `maxHeight`, if it is taller: every frame's vertical extent scaled, the pictures
    /// cropped a little rather than the album running off the screen.
    private static func fitted(_ frames: [CGRect], into maxHeight: CGFloat) -> [CGRect] {
        let height = frames.map(\.maxY).max() ?? 0
        guard height > maxHeight, height > 0 else { return frames }
        let scale = maxHeight / height
        return frames.map { CGRect(x: $0.minX, y: $0.minY * scale, width: $0.width, height: $0.height * scale) }
    }
}
