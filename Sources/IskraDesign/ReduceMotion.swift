import SwiftUI

public extension View {
    /// Honours Settings → Accessibility → Motion → Reduce Motion, for everything underneath.
    ///
    /// Applied once, at the root, rather than at each of the hundred-odd places the app animates
    /// — a message rising into place, the menu lifting a bubble, a video note growing, the typing
    /// dots and the recording pulse that never stop. Asked one at a time, some of them would be
    /// forgotten, and the one that is forgotten is the one that makes somebody feel sick.
    ///
    /// With the setting on, changes land at once instead of being animated there: no slides, no
    /// springs, no zooms, no loop. That is the strictest reading of the setting, and the honest
    /// one for an app whose motion is almost all movement rather than fades.
    func respectsReduceMotion() -> some View {
        modifier(ReduceMotion())
    }
}

private struct ReduceMotion: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.transaction { transaction in
            if reduceMotion { transaction.animation = nil }
        }
    }
}
