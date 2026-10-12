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

    /// The sticker button, inside the field at its end — and the field still a field: one line
    /// tall when empty, wrapping before it reaches the face rather than running under it.
    @Test("the sticker button sits inside the field without crowding it")
    func stickerButtonInsideTheField() throws {
        try render(draft: "", named: "composer-stickers", offersStickers: true)
        try render(draft: "A longer message that has to wrap before it reaches the sticker button at the end",
                   named: "composer-stickers-typing", offersStickers: true)
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

    /// The lock pill, mid-climb and arrived.
    ///
    /// It hangs above the record button on exactly the arithmetic the attach menu hangs on — the
    /// composer's own measured height, taken off the bottom edge — and that arithmetic has been
    /// wrong before, in the way that draws a floating control straight over the field it is
    /// supposed to float above. Same trap, same picture, so it is looked at the same way.
    @Test("the lock pill hangs above the record button rather than over the composer")
    func lockPillClearsTheComposer() throws {
        try render(draft: "",
                   named: "composer-locking",
                   locking: LockGesture(reach: 0.5, isVisible: true))

        try render(draft: "",
                   named: "composer-locked",
                   locking: LockGesture(reach: 1, isVisible: true, hasLocked: true))
    }

    private func render(draft: String,
                        named name: String,
                        isAttaching: Bool = false,
                        offersStickers: Bool = false,
                        locking: LockGesture = LockGesture()) throws {
        let view = MessageComposer(draft: .constant(draft),
                                   onSend: {},
                                   onChoosePhoto: {},
                                   onChooseFile: {},
                                   onChooseSticker: offersStickers ? {} : nil,
                                   isAttaching: isAttaching,
                                   locking: locking)
            .frame(width: 420)
            .padding(.top, isAttaching || locking.isVisible ? 140 : 16)
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
