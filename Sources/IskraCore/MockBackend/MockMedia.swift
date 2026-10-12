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

    /// What a demo sticker is a picture of.
    enum StickerArt: String, CaseIterable {
        case happy, love, wink, sleepy, surprised, cool, heart, star
    }

    /// A sticker: a shape on *nothing*, which is the whole of what makes it a sticker and not a
    /// photograph — the transparency is what the timeline has to keep, and a demo sticker on a
    /// white square would hide the one bug worth looking for.
    static func sticker(_ art: StickerArt, hue: Double) -> Data {
        render(width: 256, height: 256) { context, size in
            let fill = color(hue, 0.55, 0.98)
            let ink = color(hue, 0.7, 0.35)
            context.setLineWidth(8)
            context.setLineCap(.round)
            context.setStrokeColor(ink)
            context.setFillColor(fill)

            switch art {
            case .heart:
                context.addPath(heart(in: CGRect(x: 28, y: 28, width: 200, height: 200)))
                context.drawPath(using: .fillStroke)
                return
            case .star:
                context.addPath(star(center: CGPoint(x: 128, y: 124), outer: 110, inner: 48))
                context.drawPath(using: .fillStroke)
                return
            default:
                break
            }

            // A round face, and the mood is in the eyes and the mouth.
            let face = CGRect(x: 24, y: 20, width: 208, height: 208)
            context.fillEllipse(in: face)
            context.strokeEllipse(in: face)
            context.setFillColor(ink)

            func eye(_ x: Double, open: Bool) {
                if open {
                    context.fillEllipse(in: CGRect(x: x - 12, y: 136, width: 24, height: 32))
                } else {
                    context.move(to: CGPoint(x: x - 16, y: 148))
                    context.addLine(to: CGPoint(x: x + 16, y: 148))
                    context.strokePath()
                }
            }

            switch art {
            case .love:
                context.setFillColor(color(0.98, 0.75, 0.9))
                context.addPath(heart(in: CGRect(x: 64, y: 124, width: 44, height: 44)))
                context.addPath(heart(in: CGRect(x: 148, y: 124, width: 44, height: 44)))
                context.fillPath()
            case .wink:
                eye(90, open: true)
                eye(166, open: false)
            case .sleepy:
                eye(90, open: false)
                eye(166, open: false)
            case .cool:
                context.fill(CGRect(x: 52, y: 132, width: 152, height: 36))
            default:
                eye(90, open: true)
                eye(166, open: true)
            }

            if art == .surprised {
                context.fillEllipse(in: CGRect(x: 108, y: 56, width: 40, height: 48))
            } else if art == .sleepy {
                context.move(to: CGPoint(x: 104, y: 80))
                context.addLine(to: CGPoint(x: 152, y: 80))
                context.strokePath()
            } else {
                context.addArc(center: CGPoint(x: 128, y: 104), radius: 48,
                               startAngle: .pi * 1.15, endAngle: .pi * 1.85, clockwise: false)
                context.strokePath()
            }
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

    private static func heart(in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        let (x, y, w, h) = (rect.minX, rect.minY, rect.width, rect.height)
        path.move(to: CGPoint(x: x + w / 2, y: y))
        path.addCurve(to: CGPoint(x: x, y: y + h * 0.7),
                      control1: CGPoint(x: x + w * 0.2, y: y + h * 0.25),
                      control2: CGPoint(x: x, y: y + h * 0.45))
        path.addArc(center: CGPoint(x: x + w * 0.25, y: y + h * 0.72), radius: w * 0.25,
                    startAngle: .pi, endAngle: 0, clockwise: true)
        path.addArc(center: CGPoint(x: x + w * 0.75, y: y + h * 0.72), radius: w * 0.25,
                    startAngle: .pi, endAngle: 0, clockwise: true)
        path.addCurve(to: CGPoint(x: x + w / 2, y: y),
                      control1: CGPoint(x: x + w, y: y + h * 0.45),
                      control2: CGPoint(x: x + w * 0.8, y: y + h * 0.25))
        path.closeSubpath()
        return path
    }

    private static func star(center: CGPoint, outer: Double, inner: Double) -> CGPath {
        let path = CGMutablePath()
        for point in 0..<10 {
            let radius = point.isMultiple(of: 2) ? outer : inner
            let angle = Double.pi / 2 + Double(point) * .pi / 5
            let vertex = CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
            if point == 0 { path.move(to: vertex) } else { path.addLine(to: vertex) }
        }
        path.closeSubpath()
        return path
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
