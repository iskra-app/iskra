import Testing
import CoreGraphics
import Foundation
import ImageIO
@testable import IskraFeatures

/// The arithmetic and the cut behind `AvatarCropper`.
@Suite("Avatar crop")
struct AvatarCropTests {
    private let landscape = CGSize(width: 4000, height: 3000)

    @Test("at rest the square is the middle of the picture, its shorter side edge to edge")
    func restingCrop() {
        let crop = AvatarCrop(imageSize: landscape, side: 300)
        #expect(crop.cropRect == CGRect(x: 500, y: 0, width: 3000, height: 3000))
    }

    @Test("the picture cannot be moved so far that the square shows past its edge")
    func offsetIsHeldIn() {
        var crop = AvatarCrop(imageSize: landscape, side: 300)
        crop.offset = CGSize(width: 10_000, height: 10_000)
        #expect(crop.cropRect.minX == 0)
        #expect(crop.cropRect.minY == 0)
        crop.offset = CGSize(width: -10_000, height: 0)
        #expect(crop.cropRect.maxX == landscape.width)
    }

    @Test("zooming in takes a smaller part of the picture, and zoom stays between 1 and the most")
    func zoom() {
        let crop = AvatarCrop(imageSize: landscape, side: 300, zoom: 2)
        #expect(crop.cropRect.width == 1500)
        #expect(AvatarCrop.clampedZoom(0.2) == 1)
        #expect(AvatarCrop.clampedZoom(99) == AvatarCrop.maxZoom)
    }

    @Test("what is sent is a square no larger than the most, as a JPEG with nothing but pixels")
    func renderedSquareHasNoMetadata() throws {
        let context = try #require(CGContext(data: nil, width: 4000, height: 3000, bitsPerComponent: 8,
                                             bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 4000, height: 3000))
        let image = try #require(context.makeImage())

        let data = try #require(AvatarCrop(imageSize: landscape, side: 300).render(image))
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == Int(AvatarCrop.maxSide))
        #expect(properties[kCGImagePropertyPixelHeight] as? Int == Int(AvatarCrop.maxSide))
        #expect(properties[kCGImagePropertyGPSDictionary] == nil)
        #expect(properties[kCGImagePropertyExifDictionary] == nil
                || (properties[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifDateTimeOriginal] == nil)
    }
}
