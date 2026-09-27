import Testing
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import IskraFeatures

/// What a pasted or dropped picture becomes before it is sent.
///
/// Pinned because the Mac puts TIFF on the clipboard for nearly everything copied out of an app,
/// and a TIFF sent as it is arrives on the other end as megabytes that half the clients there
/// cannot draw. That fails nowhere near here — on somebody else's phone — so it is held here.
struct PendingAttachmentTests {
    private func picture(as type: UTType) throws -> Data {
        let context = try #require(CGContext(data: nil, width: 4, height: 3, bitsPerComponent: 8,
                                             bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 1, green: 0.4, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 3))
        let image = try #require(context.makeImage())

        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }

    @Test("a PNG goes as it came")
    func pngIsKept() throws {
        let data = try picture(as: .png)
        let image = try #require(PendingAttachment(data: data, type: .png))
        #expect(image.data == data)
        #expect(image.filename.hasSuffix(".png"))
    }

    @Test("a JPEG keeps its format and its name says so")
    func jpegIsKept() throws {
        let data = try picture(as: .jpeg)
        let image = try #require(PendingAttachment(data: data, type: .image))
        #expect(image.data == data)
        #expect(image.filename.hasSuffix(".jpeg") || image.filename.hasSuffix(".jpg"))
    }

    @Test("a TIFF from the clipboard is sent as PNG")
    func tiffBecomesPNG() throws {
        let data = try picture(as: .tiff)
        let image = try #require(PendingAttachment(data: data, type: .tiff))
        #expect(image.filename.hasSuffix(".png"))

        let source = try #require(CGImageSourceCreateWithData(image.data as CFData, nil))
        #expect(CGImageSourceGetType(source) as String? == UTType.png.identifier)
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == 4)
        #expect(properties[kCGImagePropertyPixelHeight] as? Int == 3)
    }

    @Test("the bytes decide the format, not the label a drop came with")
    func mislabelledBytesAreTakenAtTheirWord() throws {
        let data = try picture(as: .png)
        let image = try #require(PendingAttachment(data: data, type: .jpeg))
        #expect(image.filename.hasSuffix(".png"))
    }

    @Test("the composer's tile is drawn from a preview made once, and never larger than the photo")
    func previewIsMadeOnArrival() throws {
        let image = try #require(PendingAttachment(data: try picture(as: .png), type: .png))
        let preview = try #require(image.preview)
        #expect(preview.width == 4 && preview.height == 3)
        #expect(!image.isVideo)
    }

    @Test("something that is not a picture is refused, not sent")
    func nonImageIsRefused() {
        #expect(PendingAttachment(data: Data("hello".utf8), type: .png) == nil)
        #expect(PendingAttachment(data: Data(), type: .image) == nil)
    }
}
