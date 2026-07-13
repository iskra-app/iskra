import Foundation
import CoreGraphics
import ImageIO

/// The blurred shape of a picture, in about thirty characters.
///
/// A blurhash travels in the event next to the width and the height, outside the encrypted
/// attachment, and it is what a receiving client paints while the real picture is still
/// downloading — a soft impression of it rather than a grey rectangle.
///
/// It is not an optimisation here, it is a *requirement*. The SDK refuses to send an image
/// or a video without one: `BaseImageInfo::try_from` does
/// `value.blurhash.clone().ok_or(MediaInfoError::MissingField)?`, and the whole send comes
/// back as `RoomError::InvalidAttachmentData` — an error that says nothing about blurhashes,
/// arrives before a single byte reaches the network, and looks exactly like a server refusing
/// the photo. Every picture this app tried to send failed on that missing field. Files were
/// unaffected, because `BaseFileInfo` asks only for a size, which is why sending a *file*
/// worked while sending a *photo* did not.
///
/// The algorithm is the published one (woltapp/blurhash): a small discrete cosine transform
/// over the image in linear light, packed into base83. Written here from the specification
/// rather than lifted from a library, so nothing new joins the dependency list for eighty
/// lines of arithmetic.
enum Blurhash {
    /// How many terms of the transform are kept. Four by three is what every Matrix client
    /// uses and it is what the format was tuned for: enough to show where the light and the
    /// faces are, not enough to show what they are.
    private static let componentsX = 4
    private static let componentsY = 3

    private static let base83 = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz#$%*+,-.:;=?@[]^_{|}~")

    /// The hash of an image that could not be read at all: flat mid-grey.
    ///
    /// Returned instead of `nil` because the SDK will not send a picture without a hash, and
    /// a picture that arrives under a grey blur is enormously better than one that does not
    /// arrive. It is a lie about the contents of the image and an honest one about how much
    /// we know of them.
    static let neutral = "L6PZfSjE.AyE_3t7t7R**0o#DgR4"

    /// The blurhash of the picture in `data`, or the neutral one if it cannot be read.
    static func encode(imageData data: Data) -> String {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return neutral
        }
        return encode(image)
    }

    static func encode(_ image: CGImage) -> String {
        // Scaled down first. The transform reads every pixel, and a blurhash of a 48-megapixel
        // photograph is the same blurhash as one of its thumbnail — so paying for the full
        // image would be paying for nothing, on the main path of sending a picture.
        guard let pixels = Pixels(image, fitting: 64) else { return neutral }

        var factors: [(Double, Double, Double)] = []
        factors.reserveCapacity(componentsX * componentsY)

        for j in 0..<componentsY {
            for i in 0..<componentsX {
                let normalisation: Double = (i == 0 && j == 0) ? 1 : 2
                var r = 0.0, g = 0.0, b = 0.0

                for y in 0..<pixels.height {
                    for x in 0..<pixels.width {
                        let basis = normalisation
                            * cos(Double.pi * Double(i) * Double(x) / Double(pixels.width))
                            * cos(Double.pi * Double(j) * Double(y) / Double(pixels.height))
                        let (pr, pg, pb) = pixels.linear(x: x, y: y)
                        r += basis * pr
                        g += basis * pg
                        b += basis * pb
                    }
                }

                let scale = 1 / Double(pixels.width * pixels.height)
                factors.append((r * scale, g * scale, b * scale))
            }
        }

        let dc = factors[0]
        let ac = factors.dropFirst()

        var hash = ""

        let sizeFlag = (componentsX - 1) + (componentsY - 1) * 9
        hash += encode83(sizeFlag, length: 1)

        // The AC terms are stored relative to the largest of them, so the small ones keep
        // their precision. With no AC terms at all — a photograph of a blank wall — there is
        // no largest, and the divisor would be zero.
        let maximum = ac.flatMap { [abs($0.0), abs($0.1), abs($0.2)] }.max() ?? 0
        let quantisedMaximum = max(0, min(82, Int(floor(maximum * 166 - 0.5))))
        let maximumValue = maximum > 0 ? Double(quantisedMaximum + 1) / 166 : 1
        hash += encode83(quantisedMaximum, length: 1)

        hash += encode83(encodeDC(dc), length: 4)
        for factor in ac {
            hash += encode83(encodeAC(factor, maximum: maximumValue), length: 2)
        }

        return hash
    }

    // MARK: - Packing

    private static func encodeDC(_ colour: (Double, Double, Double)) -> Int {
        (sRGB(colour.0) << 16) + (sRGB(colour.1) << 8) + sRGB(colour.2)
    }

    private static func encodeAC(_ colour: (Double, Double, Double), maximum: Double) -> Int {
        func quantise(_ value: Double) -> Int {
            let signed = signPow(value / maximum, 0.5) * 9 + 9.5
            return max(0, min(18, Int(floor(signed))))
        }
        return quantise(colour.0) * 19 * 19 + quantise(colour.1) * 19 + quantise(colour.2)
    }

    private static func encode83(_ value: Int, length: Int) -> String {
        var result = ""
        for i in 1...length {
            let digit = (value / Int(pow(83.0, Double(length - i)))) % 83
            result.append(base83[digit])
        }
        return result
    }

    // MARK: - Light

    /// sRGB is not proportional to light, and averaging it as though it were is what makes a
    /// naive blur of a picture come out muddy. Everything above works in linear light and only
    /// comes back here at the very end.
    private static func linear(_ value: Double) -> Double {
        value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }

    private static func sRGB(_ value: Double) -> Int {
        let v = max(0, min(1, value))
        let encoded = v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055
        return Int(encoded * 255 + 0.5)
    }

    private static func signPow(_ value: Double, _ exponent: Double) -> Double {
        copysign(pow(abs(value), exponent), value)
    }

    // MARK: - Pixels

    /// The image, redrawn small, in a buffer we know the layout of.
    private struct Pixels {
        let width: Int
        let height: Int
        private let bytes: [UInt8]

        /// Redrawn rather than read. A `CGImage` from a photo library can be any colour space,
        /// any bit depth and any alpha arrangement; drawing it into a context of our own is
        /// what makes "the byte at 4·(y·w + x)" a true statement about it.
        init?(_ image: CGImage, fitting limit: Int) {
            let scale = min(1, Double(limit) / Double(max(image.width, image.height)))
            let width = max(1, Int(Double(image.width) * scale))
            let height = max(1, Int(Double(image.height) * scale))

            var buffer = [UInt8](repeating: 0, count: width * height * 4)
            let bitmap = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)

            // The drawing happens *inside* the closure, on purpose. A `CGContext` built on
            // `raw.baseAddress` and then used after the closure returns is writing through a
            // pointer the array no longer promises anything about — the pixels it produced
            // were partly noise, and the noise came out the other end as detail in the blur
            // of a picture that had none. `Blurhash` tests catch exactly that.
            let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
                guard let context = CGContext(data: raw.baseAddress,
                                              width: width,
                                              height: height,
                                              bitsPerComponent: 8,
                                              bytesPerRow: width * 4,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: bitmap.rawValue) else {
                    return false
                }
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }

            guard drawn else { return nil }

            self.width = width
            self.height = height
            self.bytes = buffer
        }

        func linear(x: Int, y: Int) -> (Double, Double, Double) {
            let offset = 4 * (y * width + x)
            return (Blurhash.linear(Double(bytes[offset]) / 255),
                    Blurhash.linear(Double(bytes[offset + 1]) / 255),
                    Blurhash.linear(Double(bytes[offset + 2]) / 255))
        }
    }
}
