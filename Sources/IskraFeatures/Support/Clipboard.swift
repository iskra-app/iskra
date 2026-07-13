import SwiftUI

/// Putting text on the pasteboard, which is two different APIs wearing the same hat.
///
/// One `#if os` in the app rather than one per screen that copies something. There were two
/// — the message menu and the recovery key — written in opposite branch order, which is how
/// these things start.
enum Clipboard {
    static func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}
