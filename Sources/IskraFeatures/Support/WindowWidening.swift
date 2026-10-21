#if os(macOS)
import AppKit
import SwiftUI

/// The window made wider by a sidebar's width while the sidebar is open, and narrower by the same
/// when it closes — so opening the chat's info beside the conversation adds a column to the window
/// instead of taking one out of the conversation.
///
/// What was added is remembered, and exactly that is taken back: a window the screen's edge made
/// grow leftwards goes back to where it was, and one that was already in full screen (or too wide
/// for the screen to give anything) is left alone, with nothing to take back.
@MainActor
struct WindowWidening {
    private var window: NSWindow?
    private var added: CGFloat = 0
    private var shifted: CGFloat = 0

    var isWidened: Bool { window != nil }

    /// Widens the key window by `width`, keeping it on its screen.
    mutating func widen(by width: CGFloat) {
        guard window == nil,
              let window = NSApp.keyWindow ?? NSApp.mainWindow,
              !window.styleMask.contains(.fullScreen),
              let screen = window.screen?.visibleFrame else { return }

        var frame = window.frame
        let grown = min(width, max(0, screen.width - frame.width))
        guard grown > 0 else { return }
        frame.size.width += grown
        // Past the screen's right edge, the window moves left by as much as it has to.
        let overflow = max(0, frame.maxX - screen.maxX)
        frame.origin.x -= overflow

        self.window = window
        added = grown
        shifted = overflow
        Self.animate(window, to: frame)
    }

    /// Gives back what `widen` added, if anything.
    mutating func restore() {
        guard let window else { return }
        self.window = nil
        guard !window.styleMask.contains(.fullScreen) else { return }
        var frame = window.frame
        frame.size.width = max(window.minSize.width, frame.width - added)
        frame.origin.x += shifted
        Self.animate(window, to: frame)
    }

    /// At once, not animated. The window's own animation lays the whole conversation out again on
    /// every frame of it, and a long chat made that a couple of frames a second; done at once, in
    /// the same step that opens the column, it is one layout and nothing to watch.
    private static func animate(_ window: NSWindow, to frame: NSRect) {
        window.setFrame(frame, display: true)
    }
}
#endif
