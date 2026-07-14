import Testing
import SwiftUI
import IskraDesign
@testable import IskraFeatures

/// Whether the furniture grows with the text, and whether it knows when to stop.
///
/// The app used `@ScaledMetric` nowhere at all, so every fixed measurement stayed exactly where it
/// was while the text inside it grew — two to three times larger at the accessibility sizes. The
/// send button is a 44pt circle holding an SF Symbol, and a symbol scales with the font whether its
/// button does or not: the glyph simply grew out of the circle and was clipped by it.
///
/// **iOS only, and that is not laziness.** macOS has no Dynamic Type. `@ScaledMetric` there returns
/// its base value whatever the environment says, so this same assertion under `swift test` — which
/// builds for the Mac — would compare 44 with 44, pass, and prove nothing. Run it with:
///
///     xcodebuild test -scheme Iskra-Package -only-testing:IskraFeaturesTests \
///       -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
///
/// It measures `ScaledSize` itself rather than a screen, and that is deliberate. The obvious test —
/// "the composer is taller at AX5" — passes whether the scaling exists or not, because the text
/// field inside it grows on its own and drags the composer's height up with it. A test that cannot
/// fail is worse than no test: it is a false report that the thing is covered.
@MainActor
struct DynamicTypeTests {
    /// A view whose height is nothing but the scaled size, so the number that comes out is the
    /// number that went in.
    private struct Ruler: View {
        @ScaledSize(Theme.Size.composerControl) private var control

        var body: some View {
            Color.clear.frame(width: 10, height: control)
        }
    }

    #if os(iOS)
    private func height(at size: DynamicTypeSize) -> CGFloat? {
        ImageRenderer(content: Ruler().environment(\.dynamicTypeSize, size)).uiImage?.size.height
    }

    @Test("a control grows with the reader's text")
    func itGrows() throws {
        let ordinary = try #require(height(at: .large))
        let large = try #require(height(at: .accessibility5))

        #expect(ordinary == Theme.Size.composerControl)
        #expect(large > ordinary, "the control is \(large)pt at AX5 and \(ordinary)pt at the default — it is not scaling")
    }

    /// And stops. At the largest accessibility size the system's factor is a little over three, and
    /// a send button three times larger does not make a message easier to read — it pushes the
    /// message off the side of the screen. Text may take all the room it needs; the furniture around
    /// it takes some and then stops. Without the cap this reads about 137pt.
    @Test("and stops growing before it takes the whole screen")
    func itIsCapped() throws {
        let large = try #require(height(at: .accessibility5))
        let ceiling = Theme.Size.composerControl * 1.6

        // A point of slack, because this is measured off a rendered bitmap and a bitmap has whole
        // pixels: the cap is 70.4pt and the image comes back 71. The number that matters is the one
        // this would be *without* the cap, which is about 137.
        #expect(large <= ceiling + 1, "the control reached \(large)pt, past the \(ceiling)pt ceiling")
    }
    #endif
}
