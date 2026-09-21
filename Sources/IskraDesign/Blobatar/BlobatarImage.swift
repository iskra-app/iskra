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
    public static func pngData(for seed: String,
                               size: Int = 256,
                               backdrop: Blobatar.Backdrop = .circle) -> Data? {
        guard size > 0 else { return nil }
        let figure = Blobatar.figure(for: seed, options: Blobatar.Options(backdrop: backdrop))

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

        guard let image = context.makeImage() else { return nil }
        return png(from: image)
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
