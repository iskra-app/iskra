import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The stickers the app comes with — "Искорки" — drawn in code rather than shipped as files.
///
/// Drawn, because a picture made from a few lines of Core Graphics is the same picture on every
/// device without being a file anybody has to keep, and because the app's own art is the only
/// art it can hand out without asking whose it is. The same drawings stand in the demo's packs
/// (`MockWorld`), so the demo and a real account show one set of faces.
///
/// A sticker on a server is an `mxc://` URL, and these have none until somebody needs them:
/// `StickerLibrary` uploads each once per account and remembers where, in account data. A
/// change to a drawing is a change of what everybody already has — bump `version`, and every
/// account uploads the set again on the next opening of the sheet.
enum StickerArt: String, CaseIterable, Sendable {
    case happy, laugh, love, wink, cool, surprised, sleepy, sad, crying, angry, heart, star

    /// Which drawing this is. Stored next to the uploaded set, and a set made by an older one is
    /// uploaded again.
    static let version = 1

    /// The words that stand in for the picture — the event's `body`, what VoiceOver reads.
    var emoji: String {
        switch self {
        case .happy: "😊"
        case .laugh: "😄"
        case .love: "😍"
        case .wink: "😉"
        case .cool: "😎"
        case .surprised: "😮"
        case .sleepy: "😴"
        case .sad: "😢"
        case .crying: "😭"
        case .angry: "😠"
        case .heart: "❤️"
        case .star: "⭐"
        }
    }

    var hue: Double {
        switch self {
        case .happy: 0.14
        case .laugh: 0.12
        case .love: 0.08
        case .wink: 0.16
        case .cool: 0.1
        case .surprised: 0.5
        case .sleepy: 0.6
        case .sad: 0.58
        case .crying: 0.62
        case .angry: 0.01
        case .heart: 0.98
        case .star: 0.13
        }
    }

    /// The side every sticker is drawn at. 512 is what Telegram and Element both make stickers
    /// at, so it is crisp at any size the timeline draws one.
    static let side = 512

    /// The sticker as a PNG: a shape on *nothing*. The transparency is what makes it a sticker
    /// and not a photograph.
    func png(side: Int = Self.side) -> Data {
        Self.render(side: side) { context in
            draw(in: context)
        }
    }

    // MARK: - Drawing

    /// Drawn on a 256-point square, y up, and scaled to whatever was asked for.
    private func draw(in context: CGContext) {
        let fill = Self.color(hue, 0.55, 0.98)
        let ink = Self.color(hue, 0.7, 0.35)
        context.setLineWidth(8)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setStrokeColor(ink)
        context.setFillColor(fill)

        switch self {
        case .heart:
            context.addPath(Self.heart(in: CGRect(x: 28, y: 28, width: 200, height: 200)))
            context.drawPath(using: .fillStroke)
            return
        case .star:
            context.addPath(Self.star(center: CGPoint(x: 128, y: 124), outer: 110, inner: 48))
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

        /// Shut tight with joy: a "^".
        func squint(_ x: Double) {
            context.move(to: CGPoint(x: x - 16, y: 140))
            context.addLine(to: CGPoint(x: x, y: 158))
            context.addLine(to: CGPoint(x: x + 16, y: 140))
            context.strokePath()
        }

        func smile() {
            context.addArc(center: CGPoint(x: 128, y: 104), radius: 48,
                           startAngle: .pi * 1.15, endAngle: .pi * 1.85, clockwise: false)
            context.strokePath()
        }

        func frown() {
            context.addArc(center: CGPoint(x: 128, y: 56), radius: 40,
                           startAngle: .pi * 0.2, endAngle: .pi * 0.8, clockwise: false)
            context.strokePath()
        }

        func tear(_ x: Double, length: Double) {
            context.setFillColor(Self.color(0.56, 0.45, 1.0))
            context.fill(CGRect(x: x - 10, y: 132 - length, width: 20, height: length))
            context.fillEllipse(in: CGRect(x: x - 10, y: 122 - length, width: 20, height: 20))
            context.setFillColor(ink)
        }

        switch self {
        case .love:
            context.setFillColor(Self.color(0.98, 0.75, 0.9))
            context.addPath(Self.heart(in: CGRect(x: 64, y: 124, width: 44, height: 44)))
            context.addPath(Self.heart(in: CGRect(x: 148, y: 124, width: 44, height: 44)))
            context.fillPath()
            context.setFillColor(ink)
            smile()
        case .wink:
            eye(90, open: true)
            eye(166, open: false)
            smile()
        case .sleepy:
            eye(90, open: false)
            eye(166, open: false)
            context.move(to: CGPoint(x: 104, y: 80))
            context.addLine(to: CGPoint(x: 152, y: 80))
            context.strokePath()
        case .cool:
            context.fill(CGRect(x: 52, y: 132, width: 152, height: 36))
            smile()
        case .surprised:
            eye(90, open: true)
            eye(166, open: true)
            context.fillEllipse(in: CGRect(x: 108, y: 56, width: 40, height: 48))
        case .laugh:
            squint(90)
            squint(166)
            // The open mouth: a half moon, flat side up.
            context.move(to: CGPoint(x: 76, y: 108))
            context.addArc(center: CGPoint(x: 128, y: 108), radius: 52,
                           startAngle: .pi, endAngle: 0, clockwise: false)
            context.closePath()
            context.fillPath()
        case .sad:
            eye(90, open: true)
            eye(166, open: true)
            tear(170, length: 18)
            frown()
        case .crying:
            eye(90, open: false)
            eye(166, open: false)
            tear(90, length: 56)
            tear(166, length: 56)
            frown()
        case .angry:
            eye(90, open: true)
            eye(166, open: true)
            // Brows drawn down towards the nose.
            context.move(to: CGPoint(x: 64, y: 192))
            context.addLine(to: CGPoint(x: 110, y: 176))
            context.move(to: CGPoint(x: 192, y: 192))
            context.addLine(to: CGPoint(x: 146, y: 176))
            context.strokePath()
            frown()
        default:
            eye(90, open: true)
            eye(166, open: true)
            smile()
        }
    }

    private static func render(side: Int, draw: (CGContext) -> Void) -> Data {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return Data()
        }
        context.scaleBy(x: Double(side) / 256, y: Double(side) / 256)
        draw(context)

        let output = NSMutableData()
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)
        else { return Data() }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return output as Data
    }

    private static func heart(in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        let (x, y, width, height) = (rect.minX, rect.minY, rect.width, rect.height)
        path.move(to: CGPoint(x: x + width / 2, y: y))
        path.addCurve(to: CGPoint(x: x, y: y + height * 0.7),
                      control1: CGPoint(x: x + width * 0.2, y: y + height * 0.25),
                      control2: CGPoint(x: x, y: y + height * 0.45))
        path.addArc(center: CGPoint(x: x + width * 0.25, y: y + height * 0.72), radius: width * 0.25,
                    startAngle: .pi, endAngle: 0, clockwise: true)
        path.addArc(center: CGPoint(x: x + width * 0.75, y: y + height * 0.72), radius: width * 0.25,
                    startAngle: .pi, endAngle: 0, clockwise: true)
        path.addCurve(to: CGPoint(x: x + width / 2, y: y),
                      control1: CGPoint(x: x + width, y: y + height * 0.45),
                      control2: CGPoint(x: x + width * 0.8, y: y + height * 0.25))
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
    private static func color(_ hue: Double, _ saturation: Double, _ brightness: Double) -> CGColor {
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
        return CGColor(srgbRed: red + floor, green: green + floor, blue: blue + floor, alpha: 1)
    }
}
