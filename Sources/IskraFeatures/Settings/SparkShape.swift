import SwiftUI

/// The spark itself, as a shape — the outline the app icon is drawn from.
///
/// It exists because the icon screen has to show six icons and the system will not hand any of
/// them over. An Icon Composer document is compiled by `actool` into a form that only the home
/// screen can read: `UIImage(named:)` does not return the alternates at all, and asked for the
/// primary by its bare name it does not fail politely either — it throws `Need an imageRef` and
/// takes the app with it. (The one name that does work, `iskra60x60`, exists because the primary
/// icon is also registered the old way, under `CFBundleIconFiles`. The alternates are not.) This
/// is the ordinary state of things and not a misconfiguration: Apple's own guidance for an icon
/// picker is that the app ships its own preview images.
///
/// So the tile is drawn rather than loaded, and it is drawn from the *same* vector the icon is
/// built from — `Resources/spark.svg` is a symlink to `iskra.icon/Assets/Subtract2.svg`, not a
/// copy of it. That is the whole point: a second drawing of the spark would be a second thing to
/// keep in step with the first, and the first one has already changed twice.
///
/// The parser below understands exactly what that file contains — `M`, `L`, `C` and `Z`, all
/// absolute — and nothing else. It is not an SVG renderer and should not become one: if the icon
/// is ever redrawn with arcs or relative commands in it, this returns an empty path and the tile
/// falls back to the flat ground colour, which is a visible, harmless failure rather than a
/// wrong picture.
struct SparkShape: Shape {
    /// Whether there is a spark to draw at all — what `Iskra --probe-icons` reports.
    static var isDrawable: Bool { SparkVector.shared != nil }

    func path(in rect: CGRect) -> Path {
        guard let spark = SparkVector.shared else { return Path() }

        let scale = min(rect.width / spark.size.width, rect.height / spark.size.height)
        let size = CGSize(width: spark.size.width * scale, height: spark.size.height * scale)

        return spark.path.applying(
            CGAffineTransform(scaleX: scale, y: scale)
                .concatenating(CGAffineTransform(translationX: rect.midX - size.width / 2,
                                                 y: rect.midY - size.height / 2)))
    }
}

/// The vector, read once and kept.
///
/// Parsing is cheap but not free, and the icon screen draws six of these: read from the bundle on
/// every pass of a `body` it would be read dozens of times for one screen that never changes.
private struct SparkVector {
    let path: Path
    let size: CGSize

    static let shared: SparkVector? = load()

    private static func load() -> SparkVector? {
        guard let url = Bundle.module.url(forResource: "spark", withExtension: "svg"),
              let svg = try? String(contentsOf: url, encoding: .utf8),
              let box = viewBox(in: svg),
              let commands = attribute("d", in: svg)
        else { return nil }

        let path = parse(commands)
        return path.isEmpty ? nil : SparkVector(path: path, size: box)
    }

    /// The one attribute that says how big the drawing is. Read rather than assumed: the icon has
    /// been redrawn before, and a hard-coded 747×731 would silently squash the next one.
    private static func viewBox(in svg: String) -> CGSize? {
        guard let value = attribute("viewBox", in: svg) else { return nil }
        let numbers = value.split(whereSeparator: { $0 == " " || $0 == "," }).compactMap { Double($0) }
        guard numbers.count == 4 else { return nil }
        return CGSize(width: numbers[2], height: numbers[3])
    }

    private static func attribute(_ name: String, in svg: String) -> String? {
        guard let start = svg.range(of: "\(name)=\"") else { return nil }
        guard let end = svg[start.upperBound...].firstIndex(of: "\"") else { return nil }
        return String(svg[start.upperBound..<end])
    }

    /// `M`, `L`, `C`, `Z`, absolute, and nothing else — see the note on `SparkShape`.
    private static func parse(_ commands: String) -> Path {
        var path = Path()
        var numbers: [CGFloat] = []
        var command: Character = " "
        var digits = ""

        func flushNumber() {
            if let value = Double(digits) { numbers.append(CGFloat(value)) }
            digits = ""
        }

        func apply() {
            flushNumber()
            switch command {
            case "M" where numbers.count >= 2:
                path.move(to: CGPoint(x: numbers[0], y: numbers[1]))
            case "L" where numbers.count >= 2:
                path.addLine(to: CGPoint(x: numbers[0], y: numbers[1]))
            case "C":
                // Several curves may follow one `C`, six numbers at a time, which is how this
                // file is written and how every exporter writes one.
                for start in stride(from: 0, to: numbers.count - 5, by: 6) {
                    path.addCurve(to: CGPoint(x: numbers[start + 4], y: numbers[start + 5]),
                                  control1: CGPoint(x: numbers[start], y: numbers[start + 1]),
                                  control2: CGPoint(x: numbers[start + 2], y: numbers[start + 3]))
                }
            case "Z":
                path.closeSubpath()
            default:
                break
            }
            numbers = []
        }

        for character in commands {
            switch character {
            case "M", "L", "C", "Z":
                apply()
                command = character
            case "-":
                // A minus inside a number list is a separator as well as a sign: "12.5-3.1" is
                // two numbers, and every exporter writes it that way to save bytes.
                if digits.isEmpty || digits.hasSuffix("e") || digits.hasSuffix("E") {
                    digits.append(character)
                } else {
                    flushNumber()
                    digits = "-"
                }
            case " ", ",", "\n", "\t":
                flushNumber()
            default:
                digits.append(character)
            }
        }
        apply()

        return path
    }
}
