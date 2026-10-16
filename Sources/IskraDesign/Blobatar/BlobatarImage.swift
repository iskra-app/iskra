//  The bitmap side of the blobatar port. The generator it draws is ported from blobatar
//  (https://blobatar.dev), MIT licence, Copyright (c) 2026 Alain. See Licenses/blobatar.txt.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A creature as *pixels*, for the one place that cannot be handed a view.
///
/// That place is `INImage`, which is what puts a face in the circle on a notification: it takes
/// image data and nothing else. The notification extension has no screen and 24 MB — so the
/// drawing here is Core Graphics start to finish and never touches SwiftUI, even though it fills
/// the very same paths `BlobatarView` fills. Both go through `Figure.marks(scale:)`, which is what
/// keeps the face on the lock screen the same face as the one in the chat list.
///
/// Not cached. A push is one face, once, in a process that is about to die; a cache would be
/// memory spent on a second notification that is not coming.
public enum BlobatarImage {
    /// The creature `seed` comes out as, as PNG data, or nil if the bitmap could not be made.
    ///
    /// - Parameters:
    ///   - seed: An identifier — a Matrix user ID or a room ID — never a display name. See
    ///     `Blobatar`.
    ///   - size: The side of the square, in pixels. 256 is a lock-screen avatar at 3× with room
    ///     to spare, and small enough that the whole bitmap is a quarter of a megabyte.
    ///   - backdrop: A plate behind the creature. Unlike the app — which draws a blobatar
    ///     directly on whatever is already there — a notification wants one: iOS composites this
    ///     over its own banner material, whose colour is anybody's guess, and a creature floating
    ///     on it with no ground underneath reads as a sticker rather than as somebody's face.
    ///   - tinted: Whether the plate takes the creature's own colour. blobatar's plate is a white
    ///     with one percent of the hue in it, which on a banner reads as a white disc — a hole in
    ///     the notification rather than a face. Tinted, it is a pastel of the creature's own
    ///     colour, the way a contact photo is a coloured thing and not a cut-out.
    public static func pngData(for seed: String,
                               size: Int = 256,
                               backdrop: Blobatar.Backdrop = .circle,
                               tinted: Bool = true) -> Data? {
        cgImage(for: seed, size: size, backdrop: backdrop, tinted: tinted).flatMap(png(from:))
    }

    /// The same creature as a bitmap rather than a file — for the home-screen widget, which is
    /// drawn ahead of time and archived, and is safer handed pixels than a `Canvas`.
    public static func cgImage(for seed: String,
                               size: Int = 256,
                               backdrop: Blobatar.Backdrop = .circle,
                               tinted: Bool = true) -> CGImage? {
        guard size > 0 else { return nil }
        var figure = Blobatar.figure(for: seed, options: Blobatar.Options(backdrop: backdrop))
        if tinted { figure.palette.background = plate(under: figure.palette) }

        guard let context = CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // The figure is laid out in a 100×100 box with y pointing down, the way SVG counts and the
        // way every other renderer in this port counts. A `CGContext` counts up from the bottom, so
        // the box is flipped once here rather than every coordinate being negated on its way out.
        context.translateBy(x: 0, y: CGFloat(size))
        context.scaleBy(x: 1, y: -1)

        context.setShouldAntialias(true)
        for mark in figure.marks(scale: Double(size) / 100) {
            let (r, g, b) = BlobatarPalette.components(mark.color)
            context.setFillColor(red: r, green: g, blue: b, alpha: 1)
            context.addPath(mark.path)
            context.fillPath()
        }

        return context.makeImage()
    }

    /// A pastel of the creature's own hue, pale enough to be a ground and coloured enough to be
    /// one — and, if the creature is itself pale, taken down a step so the body still stands out
    /// from it. The same floor blobatar holds its own plate to.
    static func plate(under palette: BlobatarPalette) -> BlobatarOklch {
        let hue = palette.head.h
        let pastel = BlobatarOklch(l: 0.88, c: 0.07, h: hue)
        if BlobatarPalette.contrast(palette.head, pastel) >= 1.25 { return pastel }
        return BlobatarOklch(l: 0.7, c: 0.09, h: hue)
    }

    private static func png(from image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
