import Testing
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import IskraFeatures

/// The editor's geometry, and the file it writes.
///
/// Pinned because everything in the editor is kept in the photo's own pixels and turned by hand:
/// a sign wrong in `turn()` puts the user's drawing on the other side of the photo from the thing
/// they drew it round, and the screen and the export would then disagree about where that is.
struct PhotoEditorTests {
    @Test("a quarter turn takes the left edge to the bottom, and four come back to the start")
    func turning() {
        var edits = PhotoEdits(base: CGSize(width: 400, height: 300))
        edits.crop = CGRect(x: 10, y: 20, width: 100, height: 50)
        edits.strokes = [.init(points: [CGPoint(x: 0, y: 0), CGPoint(x: 400, y: 300)], color: .red, width: 4)]
        let start = edits

        edits.turn()
        #expect(edits.size == CGSize(width: 300, height: 400))
        #expect(edits.strokes[0].points == [CGPoint(x: 0, y: 400), CGPoint(x: 300, y: 0)])
        #expect(edits.crop == CGRect(x: 20, y: 290, width: 50, height: 100))

        edits.turn(); edits.turn(); edits.turn()
        #expect(edits == start)
    }

    @Test("the picture turns exactly as what is drawn on it does")
    func pictureAgreesWithDrawing() {
        var edits = PhotoEdits(base: CGSize(width: 400, height: 300))
        let corner = CGPoint(x: 400, y: 0)
        edits.strokes = [.init(points: [corner], color: .red, width: 4)]
        for _ in 0..<4 {
            #expect(corner.applying(edits.turning) == edits.strokes[0].points[0])
            edits.turn()
        }
    }

    @Test("a corner of the frame stays on the photo and the frame never shrinks to nothing")
    func cropIsClamped() {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)
        let frame = CGRect(x: 100, y: 100, width: 100, height: 100)

        let pulledOut = CropHandle.topLeft.move(frame, by: CGSize(width: -500, height: -500), within: bounds)
        #expect(pulledOut == CGRect(x: 0, y: 0, width: 200, height: 200))

        let crushed = CropHandle.bottomRight.move(frame, by: CGSize(width: -500, height: -500), within: bounds)
        #expect(crushed.size == CGSize(width: CropHandle.smallest, height: CropHandle.smallest))

        let shoved = CropHandle.body.move(frame, by: CGSize(width: 1000, height: 0), within: bounds)
        #expect(shoved == CGRect(x: 300, y: 100, width: 100, height: 100))
    }

    @Test("a corner is found by its reach, the inside is the body, and outside is nothing")
    func handles() {
        let frame = CGRect(x: 100, y: 100, width: 200, height: 200)
        #expect(CropHandle.at(CGPoint(x: 105, y: 95), in: frame) == .topLeft)
        #expect(CropHandle.at(CGPoint(x: 300, y: 300), in: frame) == .bottomRight)
        #expect(CropHandle.at(CGPoint(x: 200, y: 200), in: frame) == .body)
        #expect(CropHandle.at(CGPoint(x: 10, y: 10), in: frame) == nil)
    }

    @Test("the file written is the frame, of the photo turned")
    @MainActor
    func export() throws {
        // Red on the left half, blue on the right.
        let width = 80, height = 60
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                             bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
        context.fill(CGRect(x: width / 2, y: 0, width: width / 2, height: height))
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))

        let photo = try #require(EditablePhoto(data: output as Data))
        #expect(photo.size == CGSize(width: 80, height: 60))

        var edits = PhotoEdits(base: photo.size)
        edits.turn()
        // Turned, it is 60 × 80 with the red at the bottom; keep the top three quarters.
        edits.crop = CGRect(x: 0, y: 0, width: 60, height: 60)

        let data = try #require(photo.render(edits))
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 60 && image.height == 60)

        // Top row blue, bottom row (the crop reaches 20 px into the red) red.
        #expect(colour(of: image, x: 30, y: 2).blue > 200)
        #expect(colour(of: image, x: 30, y: 57).red > 200)
    }

    @Test("a photo nobody changed is not written again")
    func untouched() {
        var edits = PhotoEdits(base: CGSize(width: 10, height: 10))
        #expect(edits.isUntouched)
        edits.turn()
        #expect(!edits.isUntouched)
    }

    /// One pixel, top-left origin.
    private func colour(of image: CGImage, x: Int, y: Int) -> (red: UInt8, blue: UInt8) {
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return (pixel[0], pixel[2])
    }
}
