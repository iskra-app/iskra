import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import IskraDesign

/// The creature as pixels — the form a notification can actually carry.
///
/// The golden fixture in `BlobatarTests` pins *identity*: the same seed is the same creature
/// everywhere blobatar runs, and nothing here may move those numbers. What is pinned here is the
/// far dumber set of things that stand between a correct figure and a face on a lock screen: that
/// a bitmap is produced at all, that it is the size asked for, that the same seed gives the same
/// bytes, and that something was actually drawn into it. Each of those has exactly one symptom
/// when it breaks — an empty circle on a banner — and no error anywhere.
@Suite("BlobatarImage")
struct BlobatarImageTests {
    private let seed = "@anna:matrix.org"

    private func image(_ data: Data) throws -> CGImage {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    @Test("a seed comes out as a square bitmap of the size asked for")
    func rendersAtTheRequestedSize() throws {
        let data = try #require(BlobatarImage.pngData(for: seed, size: 64))
        let image = try image(data)

        #expect(image.width == 64)
        #expect(image.height == 64)
    }

    /// The point of the whole port: no network, no state, no clock. A face that differed between
    /// the chat list and the lock screen would be two people as far as anybody looking can tell.
    @Test("the same seed is the same bytes")
    func isDeterministic() throws {
        let first = try #require(BlobatarImage.pngData(for: seed, size: 32))
        let second = try #require(BlobatarImage.pngData(for: seed, size: 32))

        #expect(first == second)
    }

    @Test("different seeds are different faces")
    func differsBySeed() throws {
        let anna = try #require(BlobatarImage.pngData(for: "@anna:matrix.org", size: 32))
        let boris = try #require(BlobatarImage.pngData(for: "@boris:matrix.org", size: 32))

        #expect(anna != boris)
    }

    /// The one failure a size check does not catch: a context that was set up, flipped, and then
    /// never drawn into. It produces a perfectly valid PNG of exactly the right dimensions, and it
    /// is blank.
    @Test("the plate is filled and the square outside it is not")
    func drawsSomething() throws {
        let data = try #require(BlobatarImage.pngData(for: seed, size: 64))
        let pixels = try opaquePixels(in: try image(data))

        // A circular plate covers rather more than two thirds of its square, and the corners of
        // that square stay empty — which together say the creature was drawn *and* that it was
        // drawn in the box, not smeared across it.
        #expect(pixels.opaque > 64 * 64 / 2)
        #expect(pixels.corner == false)
    }

    @Test("nothing is drawn into a square with no size")
    func refusesAnEmptySquare() {
        #expect(BlobatarImage.pngData(for: seed, size: 0) == nil)
    }

    /// Counts what was actually painted, and looks at one corner — which a circular plate never
    /// reaches.
    private func opaquePixels(in image: CGImage) throws -> (opaque: Int, corner: Bool) {
        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = try #require(bytes.withUnsafeMutableBytes { buffer in
            CGContext(data: buffer.baseAddress,
                      width: width,
                      height: height,
                      bitsPerComponent: 8,
                      bytesPerRow: width * 4,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        })
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        bytes = [UInt8](UnsafeBufferPointer(start: context.data?.assumingMemoryBound(to: UInt8.self),
                                            count: width * height * 4))

        let alpha = stride(from: 3, to: bytes.count, by: 4).map { bytes[$0] }
        return (alpha.count { $0 > 0 }, alpha[0] > 0)
    }
}
