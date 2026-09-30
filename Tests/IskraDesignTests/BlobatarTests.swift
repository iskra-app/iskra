import CryptoKit
import Foundation
import Testing

@testable import IskraDesign

/// Holds the port to blobatar's own golden fixture.
///
/// This is the only test in the app that asserts against somebody else's file, and it is worth
/// the awkwardness. A blobatar is an *identity*: the same person has to come out as the same
/// creature here as everywhere else blobatar runs, and "it draws something plausible" is not
/// that claim. The fixture states, for a thousand seeds, exactly which bytes the markup is — so
/// a one-ulp slip in a cosine, a rounding rule borrowed from the wrong language, or a band edge
/// typed as 0.86 instead of 0.68 fails here instead of quietly giving a few hundred people a
/// different face.
///
/// `Resources/blobatar-gen2-golden.txt` is blobatar's `test/golden/gen2.txt`, unmodified.
struct BlobatarTests {
    // MARK: - The fixture

    /// The three sections, each a list of key/value pairs in file order.
    static let golden: [String: [(key: String, value: String)]] = {
        guard let url = Bundle.module.url(forResource: "blobatar-gen2-golden", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { fatalError("the blobatar fixture is missing from the test bundle") }

        var sections: [String: [(key: String, value: String)]] = [:]
        var current = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("[") {
                current = String(line.dropFirst().dropLast())
                sections[current] = []
                continue
            }
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2 else { continue }
            sections[current, default: []].append((String(parts[0]), String(parts[1])))
        }
        return sections
    }()

    /// 16 hex characters of SHA-256, which is how the fixture records the thousand seeds it does
    /// not spell out in full.
    static func digest(_ markup: String) -> String {
        SHA256.hash(data: Data(markup.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
            .prefix(16)
            .description
    }

    /// The fixture's seed corpus, rebuilt from the templates that generated it.
    static let seeds: [String] = (0..<1000).map { i in
        switch i % 10 {
        case 0: return "user-\(i)"
        case 1: return "alain\(i)@example.com"
        case 2:
            // `(i * 2654435761 >>> 0).toString(16).padStart(8, "0").repeat(4)` — the product
            // stays exact in a Double for i < 1000, and `>>> 0` is the low 32 bits of it.
            let wrapped = UInt32(truncatingIfNeeded: i * 2_654_435_761)
            let hex = String(format: "%08x", wrapped)
            return String(repeating: hex, count: 4)
        case 3: return "Team Rocket \(i)"
        case 4: return "café-\(i)"
        case 5: return "Ünïcødé \(i)"
        case 6: return "🦊\(i)🌱"
        case 7: return "\(i)"
        case 8: return "00000000-0000-4000-8000-" + String(format: "%012d", i)
        default: return "  Mixed Case \(i)  "
        }
    }

    // MARK: - The hash

    @Test func normalizationFoldsWhatAPersonConsidersTheSameName() throws {
        // NFC, so a decomposed "é" is the same person as a precomposed one.
        #expect(BlobatarHash.normalize("cafe\u{0301}") == BlobatarHash.normalize("café"))
        #expect(BlobatarHash.normalize("  @Boris:Matrix.org  ") == "@boris:matrix.org")
    }

    @Test func oneLetterChangesTheWholeCreature() throws {
        // Avalanche is the point of the murmur3 finalizer: neighbouring seeds must not come out
        // as neighbouring faces.
        let boris = Blobatar.figure(for: "@boris:matrix.org")
        let borys = Blobatar.figure(for: "@borys:matrix.org")
        #expect(
            BlobatarPalette.hex(boris.palette.head) != BlobatarPalette.hex(borys.palette.head)
                || boris.shape != borys.shape
        )
    }

    @Test func theSameSeedIsTheSameFaceEveryTime() throws {
        #expect(
            Blobatar.svg(for: "@boris:matrix.org") == Blobatar.svg(for: "@boris:matrix.org")
        )
    }

    // MARK: - Parity with the fixture

    /// The band table, over twenty thousand seeds. Catches an edge that moved by a thousandth,
    /// which no handful of examples would.
    @Test func shapeDistributionMatchesTheFixture() throws {
        var counts: [String: Int] = [:]
        for i in 0..<20_000 {
            counts[Blobatar.figure(for: "histogram-\(i)").shape, default: 0] += 1
        }

        let expected = try #require(Self.golden["histogram"])
        #expect(!expected.isEmpty)
        for (shape, count) in expected {
            #expect(counts[shape] == Int(count), "\(shape): \(counts[shape] ?? 0) vs \(count)")
        }
    }

    /// The ten silhouettes and the rendering options, as whole markup.
    ///
    /// The expression cases in the fixture are skipped: expressions are a separate layer of
    /// blobatar that this app does not use and this port does not carry.
    @Test func markupMatchesTheFixture() throws {
        // Midpoints of the ten bands, which is how the fixture pins each silhouette.
        let midpoints: [String: Double] = [
            "round": 0.11, "organic": 0.35, "boxy": 0.54, "capsule": 0.65, "nub": 0.745,
            "cloud": 0.825, "droplet": 0.888, "hexagon": 0.933, "sun": 0.965, "triangle": 0.99,
        ]

        var checked = 0
        for (label, expected) in try #require(Self.golden["markup"]) {
            var seed = "alain"
            var options = Blobatar.Options()

            if let shape = label.hasPrefix("shape:")
                ? midpoints[String(label.dropFirst("shape:".count))] : nil {
                options.traits = ["shape": [shape]]
            } else {
                switch label {
                case "plain": break
                case "backdrop": options.backdrop = .squircle
                case "titled": options.title = "Alain"
                case "sized": options.size = 64
                case "configured":
                    options.traits = ["shape": [0.96], "eye.ratio": [0], "hue": [0.5]]
                case "astral": seed = "🦊"
                // Posed and tinted are expression cases; see the note above.
                default: continue
                }
            }

            #expect(Blobatar.svg(for: seed, options: options) == expected, "case \(label)")
            checked += 1
        }
        // All ten silhouettes plus the six option cases that are not expressions.
        #expect(checked == 16)
    }

    /// A thousand seeds, by digest — the broad sweep the fixture exists for.
    @Test func everySeedInTheFixtureRendersTheSameBytes() throws {
        let expected = Dictionary(
            uniqueKeysWithValues: try #require(Self.golden["hashes"]).map { ($0.key, $0.value) }
        )

        var checked = 0
        for seed in Self.seeds {
            guard let want = expected[seed] else { continue }
            #expect(Self.digest(Blobatar.svg(for: seed)) == want, "seed \(seed)")
            checked += 1
        }
        #expect(checked == 1000)
    }

    /// The same thousand-seed corpus again, with each rendering option this port carries.
    @Test func renderingOptionsMatchTheFixture() throws {
        let expected = Dictionary(
            uniqueKeysWithValues: try #require(Self.golden["hashes"]).map { ($0.key, $0.value) }
        )
        let cases: [(String, Blobatar.Options)] = [
            ("bg:none", Blobatar.Options(backdrop: .none)),
            ("bg:square", Blobatar.Options(backdrop: .square)),
            ("bg:circle", Blobatar.Options(backdrop: .circle)),
            ("bg:squircle", Blobatar.Options(backdrop: .squircle)),
            ("hue:0", Blobatar.Options(hue: 0)),
            ("hue:210", Blobatar.Options(hue: 210)),
            ("hue:359", Blobatar.Options(hue: 359)),
            ("tone:0", Blobatar.Options(tone: 0)),
            ("tone:0.5", Blobatar.Options(tone: 0.5)),
            ("tone:0.999", Blobatar.Options(tone: 0.999)),
            ("size:8", Blobatar.Options(size: 8)),
            ("size:1024", Blobatar.Options(size: 1024)),
            ("normalize:false", Blobatar.Options(normalize: false)),
        ]

        var checked = 0
        // The fixture sweeps the options over the first twelve seeds only.
        for seed in Self.seeds.prefix(12) {
            for (label, options) in cases {
                guard let want = expected["\(seed)\u{0}\(label)"] else { continue }
                #expect(
                    Self.digest(Blobatar.svg(for: seed, options: options)) == want,
                    "seed \(seed), \(label)"
                )
                checked += 1
            }
        }
        #expect(checked == 12 * cases.count)
    }
}
