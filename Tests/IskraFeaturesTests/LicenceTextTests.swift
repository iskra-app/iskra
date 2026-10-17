import Testing
import Foundation
@testable import IskraFeatures

/// Guards the licences screen against the two ways it would fail without a sound.
///
/// A licence whose file is missing from the bundle opens onto an empty page — the notice is
/// "there", and says nothing. And the app's own licence texts are *copies*: `LICENSE` and
/// `LICENSE-EXCEPTION.md` at the root are the ones people edit, and a copy that drifted from
/// them would put one set of terms on GitHub and another in the shipped app.
struct LicenceTextTests {
    private static let repository = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    @Test("every licence on the screen has a text to show")
    func everyLicenceHasText() {
        for licence in [Licence.iskra, .iskraStorePermission] + Licence.builtOn {
            #expect(licence.url != nil, "\(licence.name): \(licence.file).\(licence.fileExtension) is not in the bundle")
            #expect(licence.paragraphs.count > 1, "\(licence.name): the text is empty")
        }
    }

    @Test("the bundled copies are the licence in the repository, byte for byte",
          arguments: [("LICENSE", Licence.iskra), ("LICENSE-EXCEPTION.md", .iskraStorePermission),
                      ("Licenses/blobatar.txt", Licence.builtOn.first { $0.name == "blobatar" }!)])
    func bundledCopiesMatchTheRepository(source: String, licence: Licence) throws {
        let original = try Data(contentsOf: Self.repository.appending(path: source))
        let bundled = try Data(contentsOf: #require(licence.url))
        #expect(bundled == original, "Sources/IskraFeatures/Resources/\(licence.file).\(licence.fileExtension) differs from \(source) — copy it again")
    }

    @Test("a hard-wrapped paragraph is joined into one")
    func paragraphsAreUnwrapped() throws {
        let gpl = Licence.iskra.paragraphs
        let preamble = try #require(gpl.first { $0.hasPrefix("The GNU General Public License is a free") })
        #expect(!preamble.contains("\n"))
        #expect(preamble.contains("copyleft license for software and other kinds of works."))
    }
}
