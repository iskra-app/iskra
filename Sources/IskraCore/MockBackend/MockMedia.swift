import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The pictures and sounds the demo server hands out, drawn on the spot.
///
/// Drawn rather than shipped: a bundle of stock photographs would be megabytes in the app for a
/// feature nobody but the person testing it will ever open, and a picture that is made from a
/// seed is the same picture every launch without being a file anybody has to keep.
enum MockMedia {
    /// A square picture for a face or a room: a two-colour gradient with a disc on it.
    static func avatar(hue: Double) -> Data {
        render(width: 256, height: 256) { context, size in
            gradient(context, size, top: color(hue, 0.55, 0.95), bottom: color(hue + 0.08, 0.75, 0.70))
            context.setFillColor(color(hue + 0.5, 0.25, 1.0, alpha: 0.85))
            context.fillEllipse(in: CGRect(x: size.width * 0.28, y: size.height * 0.22,
                                           width: size.width * 0.44, height: size.height * 0.44))
        }
    }

    /// A landscape "photograph": sky, a sun, and two rows of hills.
    static func photo(hue: Double, width: Int = 1200, height: Int = 800) -> Data {
        render(width: width, height: height) { context, size in
            gradient(context, size, top: color(hue, 0.35, 0.98), bottom: color(hue + 0.05, 0.55, 0.85))
            context.setFillColor(color(0.12, 0.6, 1.0))
            context.fillEllipse(in: CGRect(x: size.width * 0.66, y: size.height * 0.58,
                                           width: size.height * 0.22, height: size.height * 0.22))
            hills(context, size, base: 0.38, amplitude: 0.08, phase: 0.3, fill: color(hue + 0.3, 0.45, 0.62))
            hills(context, size, base: 0.22, amplitude: 0.06, phase: 1.7, fill: color(hue + 0.33, 0.55, 0.42))
        }
    }

    /// A few seconds of a soft two-note tone, as 16-bit mono WAV — a voice message that plays.
    static func voice(seconds: Double = 4) -> (data: Data, waveform: [Int]) {
        let rate = 16_000
        let count = Int(Double(rate) * seconds)
        var samples = [Int16](repeating: 0, count: count)
        for i in 0..<count {
            let time = Double(i) / Double(rate)
            let envelope = (sin(time * 2.3) * 0.5 + 0.5) * min(1, time * 8) * min(1, (seconds - time) * 8)
            let tone = sin(2 * .pi * 220 * time) * 0.6 + sin(2 * .pi * 330 * time) * 0.4
            samples[i] = Int16(max(-1, min(1, tone * envelope * 0.5)) * Double(Int16.max))
        }

        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + count * 2))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(rate)); append(UInt32(rate * 2)); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(UInt32(count * 2))
        samples.withUnsafeBytes { data.append(contentsOf: $0) }

        // The same envelope, sampled into the 0…1024 bars a voice message carries.
        let waveform = (0..<48).map { bar -> Int in
            let time = seconds * Double(bar) / 48
            return Int((sin(time * 2.3) * 0.5 + 0.5) * 900 + 100)
        }
        return (data, waveform)
    }

    // MARK: - Drawing

    private static func render(width: Int, height: Int,
                               draw: (CGContext, CGSize) -> Void) -> Data {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return Data()
        }
        draw(context, CGSize(width: width, height: height))

        let output = NSMutableData()
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)
        else { return Data() }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return output as Data
    }

    private static func gradient(_ context: CGContext, _ size: CGSize, top: CGColor, bottom: CGColor) {
        guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                        colors: [bottom, top] as CFArray, locations: [0, 1]) else { return }
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
    }

    // A drawing call: where the hills stand, how high, how far along, and what colour.
    // swiftlint:disable:next function_parameter_count
    private static func hills(_ context: CGContext, _ size: CGSize, base: Double, amplitude: Double,
                              phase: Double, fill: CGColor) {
        let path = CGMutablePath()
        path.move(to: .zero)
        for step in 0...60 {
            let x = size.width * Double(step) / 60
            let y = size.height * (base + amplitude * sin(Double(step) / 60 * .pi * 3 + phase))
            path.addLine(to: CGPoint(x: x, y: y))
        }
        path.addLine(to: CGPoint(x: size.width, y: 0))
        path.closeSubpath()
        context.addPath(path)
        context.setFillColor(fill)
        context.fillPath()
    }

    /// HSB, since that is the space in which "the same picture, another colour" is one number.
    private static func color(_ hue: Double, _ saturation: Double, _ brightness: Double,
                              alpha: Double = 1) -> CGColor {
        let sector = (hue.truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1) * 6
        let chroma = brightness * saturation
        let second = chroma * (1 - abs(sector.truncatingRemainder(dividingBy: 2) - 1))
        let floor = brightness - chroma
        // swiftlint:disable:next large_tuple
        let (red, green, blue): (Double, Double, Double) = switch Int(sector) {
        case 0: (chroma, second, 0)
        case 1: (second, chroma, 0)
        case 2: (0, chroma, second)
        case 3: (0, second, chroma)
        case 4: (second, 0, chroma)
        default: (chroma, 0, second)
        }
        return CGColor(srgbRed: red + floor, green: green + floor, blue: blue + floor, alpha: alpha)
    }
}
