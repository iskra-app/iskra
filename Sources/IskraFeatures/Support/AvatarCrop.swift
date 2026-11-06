import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Where a picture sits inside the square an avatar is cut from, and the cutting.
///
/// The arithmetic of `AvatarCropper`, kept out of the view so it can be tested without one. The
/// picture starts filling the square — its shorter side edge to edge, centred — and can be zoomed
/// in up to `maxZoom` and moved, never so far that the square shows anything but picture.
///
/// What is uploaded is the square, at most `maxSide` pixels a side, as a fresh JPEG with nothing
/// but pixels in it: a photo straight from the library carries where and when it was taken, and an
/// avatar is the most public picture a person has.
struct AvatarCrop {
    /// The picture's size in pixels, already the right way up.
    let imageSize: CGSize
    /// The square's side on screen, in points.
    let side: CGFloat
    /// 1 is the picture filling the square; more is closer.
    var zoom: CGFloat = 1
    /// How far the picture's centre is from the square's, in points on screen.
    var offset: CGSize = .zero

    static let maxZoom: CGFloat = 4
    static let maxSide: CGFloat = 1024

    /// Points on screen per pixel of the picture, at this zoom.
    var scale: CGFloat {
        guard imageSize.width > 0, imageSize.height > 0 else { return 1 }
        return side / min(imageSize.width, imageSize.height) * zoom
    }

    /// The picture's size on screen.
    var displayedSize: CGSize {
        CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    }

    /// `offset`, held in so the picture always covers the square.
    func clamped(_ offset: CGSize) -> CGSize {
        let slackX = max(0, (displayedSize.width - side) / 2)
        let slackY = max(0, (displayedSize.height - side) / 2)
        return CGSize(width: min(slackX, max(-slackX, offset.width)),
                      height: min(slackY, max(-slackY, offset.height)))
    }

    static func clampedZoom(_ zoom: CGFloat) -> CGFloat {
        min(maxZoom, max(1, zoom))
    }

    /// The square, in the picture's own pixels, top-left origin.
    var cropRect: CGRect {
        let offset = clamped(self.offset)
        let length = side / scale
        let centre = CGPoint(x: imageSize.width / 2 - offset.width / scale,
                             y: imageSize.height / 2 - offset.height / scale)
        return CGRect(x: centre.x - length / 2, y: centre.y - length / 2, width: length, height: length)
    }

    /// The square, cut out of `image` and made no larger than `maxSide`, as a JPEG with no
    /// metadata at all.
    func render(_ image: CGImage) -> Data? {
        let crop = cropRect
        let out = min(Self.maxSide, crop.width).rounded(.down)
        guard out >= 1,
              let context = CGContext(data: nil, width: Int(out), height: Int(out), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        let k = out / crop.width
        // Core Graphics counts up from the bottom; the crop is measured down from the top.
        context.draw(image, in: CGRect(x: -crop.minX * k,
                                       y: -(imageSize.height - crop.maxY) * k,
                                       width: imageSize.width * k,
                                       height: imageSize.height * k))
        guard let cut = context.makeImage() else { return nil }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, cut, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// The picked bytes as a picture the right way up — the orientation a phone camera only notes
    /// down applied to the pixels — and no larger than anybody could zoom into usefully.
    static func image(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide * maxZoom,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
