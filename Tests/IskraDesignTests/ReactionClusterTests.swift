import Testing
@testable import IskraDesign

@Suite("Reactions on a bubble")
struct ReactionClusterTests {
    @Test("an emoji's tilt is bounded and stays put")
    func tilt() {
        let seeds = (0..<200).map { "$event\($0)👍" }
        let tilts = seeds.map(Theme.Reaction.tilt(for:))
        #expect(tilts.allSatisfy { abs($0) <= Theme.Reaction.maxTilt })
        #expect(Set(tilts).count > 10)
        #expect(tilts == seeds.map(Theme.Reaction.tilt(for:)))
    }
}
