import CoreGraphics
import Testing
@testable import IskraDesign

/// The numbers the calm look promises — see `docs/DESIGN-CALM.md`.
@Suite("Calm theme")
struct CalmThemeTests {
    private typealias Tones = Theme.Calm.Tones

    private func contrast(_ a: Theme.Calm.Tone, on b: Theme.Calm.Tone, dark: Bool) -> Double {
        let (one, two) = (a.luminance(dark: dark), b.luminance(dark: dark))
        return (max(one, two) + 0.05) / (min(one, two) + 0.05)
    }

    /// Everything that carries words holds 4.5:1 on what it is written on, in both appearances.
    @Test("words hold 4.5:1 on what they are written on", arguments: [false, true])
    func wordsAreReadable(dark: Bool) {
        #expect(contrast(Tones.ink, on: Tones.ground, dark: dark) >= 4.5)
        #expect(contrast(Tones.inkSoft, on: Tones.ground, dark: dark) >= 4.5)
        #expect(contrast(Tones.trashInk, on: Tones.ground, dark: dark) >= 4.5)
        #expect(contrast(Tones.onAccent, on: Tones.keep, dark: dark) >= 4.5)
        #expect(contrast(Tones.onAccent, on: Tones.trash, dark: dark) >= 4.5)
    }

    /// An emoji leans within its limit, and the same way every time its message is drawn.
    @Test("an emoji's tilt is bounded and stays put")
    func tilt() {
        let seeds = (0..<200).map { "$event\($0)👍" }
        let tilts = seeds.map(Theme.Calm.Reaction.tilt(for:))
        #expect(tilts.allSatisfy { abs($0) <= Theme.Calm.Reaction.maxTilt })
        #expect(Set(tilts).count > 10)
        #expect(tilts == seeds.map(Theme.Calm.Reaction.tilt(for:)))
    }

    private func picture(red: CGFloat, green: CGFloat, blue: CGFloat) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: red, green: green, blue: blue, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        return try #require(context.makeImage())
    }

    /// A conversation takes its avatar's colour, and a grey avatar has none to give.
    @Test("an avatar's colour is read off the picture")
    func avatarHue() throws {
        let blue = try #require(CalmBackdrop.dominantHue(of: picture(red: 0, green: 0, blue: 1)))
        #expect(abs(blue - 2.0 / 3) < 0.02)
        let green = try #require(CalmBackdrop.dominantHue(of: picture(red: 0, green: 1, blue: 0)))
        #expect(abs(green - 1.0 / 3) < 0.02)
        #expect(CalmBackdrop.dominantHue(of: try picture(red: 0.5, green: 0.5, blue: 0.5)) == nil)
    }

    /// A picture of one colour with a square of another in its middle.
    private func picture(ground: (CGFloat, CGFloat, CGFloat), centre: (CGFloat, CGFloat, CGFloat)) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: ground.0, green: ground.1, blue: ground.2, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        context.setFillColor(red: centre.0, green: centre.1, blue: centre.2, alpha: 1)
        context.fill(CGRect(x: 24, y: 24, width: 16, height: 16))
        return try #require(context.makeImage())
    }

    @Test("a small bright object beats a big grey picture")
    func redOnGrey() throws {
        let hue = try #require(CalmBackdrop.dominantHue(of: picture(ground: (0.5, 0.5, 0.5), centre: (0.9, 0.1, 0.1))))
        #expect(hue < 0.03 || hue > 0.97)
    }

    @Test("a small bright object beats a big washed-out colour")
    func redOnPaleBlue() throws {
        let hue = try #require(CalmBackdrop.dominantHue(of: picture(ground: (0.6, 0.7, 0.85), centre: (0.9, 0.05, 0.05))))
        #expect(hue < 0.03 || hue > 0.97)
    }

    @Test("two colours give one of them and not the mix")
    func noMixing() throws {
        let hue = try #require(CalmBackdrop.dominantHue(of: picture(ground: (0, 0, 1), centre: (1, 0, 0))))
        #expect(abs(hue - 2.0 / 3) < 0.03)
    }

    /// A room's shade is the same on every launch, which `String.hashValue` would not give.
    @Test("a room's shade does not change between launches")
    func shadeIsStable() {
        #expect(CalmBackdrop.hue(for: "!room:matrix.org") == CalmBackdrop.hue(for: "!room:matrix.org"))
        #expect(CalmBackdrop.hue(for: "!room:matrix.org") == 58.0 / 360)
        #expect(CalmBackdrop.hue(for: "!room:matrix.org") != CalmBackdrop.hue(for: "!other:matrix.org"))
        #expect((0..<1).contains(CalmBackdrop.hue(for: "")))
    }
}
