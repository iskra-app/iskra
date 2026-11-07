import IskraCore
import SwiftUI

/// SF Rounded on all the text under this view, when it has been asked for in Beta features. Goes at
/// the root of a window: nothing in the app names a font of its own, so it reaches everything.
struct RoundedFont: ViewModifier {
    @AppStorage(BetaFeatures.roundedFontKey) private var isOn = BetaFeatures.roundedFontByDefault

    func body(content: Content) -> some View {
        content.fontDesign(isOn ? .rounded : nil)
    }
}

extension View {
    func roundedFontIfAsked() -> some View {
        modifier(RoundedFont())
    }
}
