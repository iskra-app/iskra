import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Putting the keyboard away from somewhere that does not own the text field it belongs to.
///
/// The composer holds its own `@FocusState`, and that is right — but a tap on a quoted message is
/// in the timeline, which cannot reach it. Resigning the first responder is the one call that
/// works from anywhere, and it does nothing at all when no field has focus.
@MainActor
enum Keyboard {
    static func dismiss() {
        #if canImport(UIKit)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                        to: nil, from: nil, for: nil)
        #endif
    }
}
