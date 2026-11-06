import Testing
import Foundation
@testable import IskraFeatures

/// Guards the way the icon picker fails: silently.
///
/// The tiles show pictures of the icons, because a compiled `.icon` cannot be got back out of the
/// bundle as one — see `HomeIcon.preview`. A picture that is missing, or named a hair differently
/// from the icon it belongs to, draws nothing at all: no error, no log, just a blank square with a
/// name under it. That is exactly what happened once already, when the tile asked for the picture
/// by name through `Image(_:bundle:)`, which looks only in an asset catalog and finds nothing in a
/// SwiftPM resource directory.
///
/// So this holds the two halves together: every icon the picker offers has a file, and every file
/// shipped belongs to an icon the picker offers. Add a ninth icon without exporting its PNG and
/// this fails; rename an icon and forget the picture, likewise.
struct HomeIconPreviewTests {
    @Test("every icon has a picture to show")
    func everyIconHasAPreview() {
        for icon in HomeIcon.allCases {
            #expect(icon.previewURL != nil, "icon-\(icon.rawValue).png is not in the bundle")
        }
    }

    @Test("and no picture is shipped for an icon that no longer exists")
    func noOrphanedPreviews() throws {
        let shipped = try #require(Bundle.module.urls(forResourcesWithExtension: "png", subdirectory: nil))
            .map { $0.deletingPathExtension().lastPathComponent }
            .filter { $0.hasPrefix("icon-") }

        let expected = Set(HomeIcon.allCases.map { "icon-\($0.rawValue)" })
        #expect(Set(shipped) == expected)
    }

    /// The names are the icons' own, and the bundle names are made from them, so a typo in one
    /// place is a typo in both and neither test above would notice. This is the list written out
    /// once, by hand, the way `LocalizationTests` writes out the translations.
    @Test("the eight are the eight")
    func theSetIsWhatItSaysItIs() {
        #expect(HomeIcon.allCases.map(\.rawValue) == [
            "iskra",
            "iskra-chrome",
            "iskra-garnet",
            "iskra-brat",
            "iskra-rio-de-janeiro",
            "iskra-black-white",
            "iskra-retro",
            "iskra-letters"
        ])
    }
}
