import Testing
import SwiftUI
@testable import IskraFeatures

#if os(macOS)
import AppKit
#endif

/// Renders the composer to a PNG so its layout can actually be looked at.
///
/// The composer normally only appears inside a room, behind a signed-in session, which
/// makes "does it look right" an expensive question. Pulling it out into its own view
/// made it a cheap one: it renders on its own, with no Matrix behind it.
@MainActor
struct ComposerLayoutTests {
    /// Where the images land. Set `ISKRA_RENDER_DIR` to collect them.
    private var outputDirectory: URL? {
        ProcessInfo.processInfo.environment["ISKRA_RENDER_DIR"].map { URL(filePath: $0) }
    }

    @Test("the composer renders in both states")
    func rendersBothStates() throws {
        try render(draft: "", named: "composer-empty")
        try render(draft: "Hey, are you around?", named: "composer-typing")
    }

    /// The attach menu open, with room above the composer for it to open *into*.
    ///
    /// The choices used to be drawn straight over the text field and the buttons — a menu
    /// covering the thing it belongs to — and nothing caught it, because the composer was
    /// only ever rendered closed. The padding here is what leaves the space they hang in: an
    /// image cropped to the composer's own bounds would clip them away and prove nothing.
    @Test("the attach menu opens above the composer, not on top of it")
    func attachMenuClearsTheComposer() throws {
        try render(draft: "", named: "composer-attaching", isAttaching: true)
    }

    private func render(draft: String, named name: String, isAttaching: Bool = false) throws {
        let view = MessageComposer(draft: .constant(draft),
                                   onSend: {},
                                   onRecordVideoNote: {},
                                   onChoosePhoto: {},
                                   onChooseFile: {},
                                   isAttaching: isAttaching)
            .frame(width: 420)
            .padding(.top, isAttaching ? 140 : 16)
            .padding([.horizontal, .bottom])
            .background(.background)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2

        #if os(macOS)
        let image = try #require(renderer.nsImage, "the composer failed to render at all")

        // A composer that renders as a sliver is a composer that is broken, whatever it
        // looks like in the picture.
        #expect(image.size.width > 400)
        #expect(image.size.height > 40)

        guard let directory = outputDirectory else { return }

        let tiff = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiff))
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: directory.appending(component: "\(name).png"))
        #endif
    }
}
