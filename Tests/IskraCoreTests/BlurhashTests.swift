import Testing
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import IskraCore

/// The blurhash is the field whose absence killed every picture this app tried to send: the
/// SDK requires it, and refuses the whole attachment — before any network call — with an
/// error that mentions neither blurhashes nor images. So these tests are not about how pretty
/// the blur is. They are about the hash existing, being the shape the format demands, and
/// actually describing the picture rather than being a constant.
struct BlurhashTests {
    /// A solid colour, drawn at a size worth downscaling.
    private func solid(red: Double, green: Double, blue: Double) -> CGImage {
        let context = CGContext(data: nil,
                                width: 120,
                                height: 90,
                                bitsPerComponent: 8,
                                bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: red, green: green, blue: blue, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 120, height: 90))
        return context.makeImage()!
    }

    /// Four components across and three down: 1 char for the size, 1 for the maximum, 4 for
    /// the flat colour, then 2 for each of the remaining 11 terms.
    @Test("a hash is the length the format demands")
    func hashIsWellFormed() {
        let hash = Blurhash.encode(solid(red: 0.9, green: 0.2, blue: 0.2))

        #expect(hash.count == 6 + 2 * (4 * 3 - 1))
        #expect(hash.allSatisfy { "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz#$%*+,-.:;=?@[]^_{|}~".contains($0) })
    }

    /// The whole point of the thing. A hash that came out the same for a red picture and a
    /// blue one would still be *accepted* by the SDK — this is the test that says it is a
    /// description and not a formality.
    @Test("different pictures get different hashes")
    func hashDescribesThePicture() {
        let red = Blurhash.encode(solid(red: 0.9, green: 0.1, blue: 0.1))
        let blue = Blurhash.encode(solid(red: 0.1, green: 0.1, blue: 0.9))
        let white = Blurhash.encode(solid(red: 1, green: 1, blue: 1))

        #expect(red != blue)
        #expect(red != white)
        #expect(blue != white)
    }

    /// The average colour of the picture is the first thing in the hash, and the one part of
    /// it that can be read back without decoding the whole blur: characters 2…5 are the flat
    /// colour, packed as 24-bit sRGB in base83.
    ///
    /// This is the test that keeps the light honest. The transform works in *linear* light and
    /// only converts back to sRGB at this last step; drop either conversion and a mid-grey
    /// picture still produces a perfectly well-formed hash — of the wrong grey. Nothing else
    /// here would notice, and on screen it would look like a slightly-off blur that nobody
    /// could name.
    @Test("the flat colour in the hash is the colour of the picture")
    func dcTermIsTheAverageColour() throws {
        for (red, green, blue) in [(0.5, 0.5, 0.5), (0.9, 0.2, 0.2), (0.0, 0.0, 0.0), (1.0, 1.0, 1.0)] {
            let hash = Array(Blurhash.encode(solid(red: red, green: green, blue: blue)))
            let packed = try #require(decode83(String(hash[2..<6])))

            let expected = [red, green, blue].map { Int(($0 * 255).rounded()) }
            let actual = [(packed >> 16) & 255, (packed >> 8) & 255, packed & 255]

            for (channel, (was, wanted)) in zip(actual, expected).enumerated() {
                // Two levels of slack for the rounding that a downscale and two colour-space
                // conversions are entitled to; a lost conversion is out by dozens.
                #expect(abs(was - wanted) <= 2,
                        "channel \(channel) of (\(red), \(green), \(blue)) came back as \(was), not \(wanted)")
            }
        }
    }

    private func decode83(_ string: String) -> Int? {
        let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz#$%*+,-.:;=?@[]^_{|}~")
        var value = 0
        for character in string {
            guard let digit = alphabet.firstIndex(of: character) else { return nil }
            value = value * 83 + digit
        }
        return value
    }

    /// Bytes that are not a picture at all still have to produce a hash, because a photo the
    /// SDK will not send is worse than one that arrives under a grey blur.
    @Test("unreadable bytes still yield a usable hash")
    func unreadableDataFallsBack() {
        let hash = Blurhash.encode(imageData: Data([0x00, 0x01, 0x02]))

        #expect(hash == Blurhash.neutral)
        #expect(!hash.isEmpty)
    }

    /// The picture, through the door the app actually uses: bytes in, metadata out.
    @Test("a picked photo arrives with everything the SDK requires")
    func pickedPhotoCarriesItsBlurhash() throws {
        let png = try #require(pngData(of: solid(red: 0.2, green: 0.6, blue: 0.9)))
        let info = MediaMetadata.image(data: png, filename: "photo.png")

        #expect(info.width == 120)
        #expect(info.height == 90)
        #expect(info.mimeType == "image/png")
        #expect(info.size == UInt64(png.count))
        // The field the SDK refuses the send without.
        #expect(!info.blurhash.isEmpty)
        #expect(info.blurhash != Blurhash.neutral)
    }

    private func pngData(of image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil as CFDictionary?)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
