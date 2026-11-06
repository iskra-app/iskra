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

    /// A room's shade is the same on every launch, which `String.hashValue` would not give.
    @Test("a room's shade does not change between launches")
    func shadeIsStable() {
        #expect(CalmBackdrop.hue(for: "!room:matrix.org") == CalmBackdrop.hue(for: "!room:matrix.org"))
        #expect(CalmBackdrop.hue(for: "!room:matrix.org") == 58.0 / 360)
        #expect(CalmBackdrop.hue(for: "!room:matrix.org") != CalmBackdrop.hue(for: "!other:matrix.org"))
        #expect((0..<1).contains(CalmBackdrop.hue(for: "")))
    }
}
