#if DEBUG && os(macOS)
import AppKit
import IskraCore

/// `Iskra --probe-resize`: opens the first chat and drags the window's width back and forth, the
/// way a hand on its edge would, then puts the window back and quits — "survived" on the console,
/// or a crash report if it did not.
///
/// It exists because the layout loops that end a Mac app (`_postWindowNeedsUpdateConstraints`)
/// only happen with a real conversation on screen and a window being resized, and nobody can be
/// asked to drag a window fifty times to see whether a change fixed one.
@MainActor
enum ResizeProbe {
    static var isRequested: Bool { CommandLine.arguments.contains("--probe-resize") }

    /// Steps of the drag, how far each goes, and how long each frame is given.
    private static let passes = 4
    private static let step: CGFloat = 12
    private static let reach: CGFloat = 600

    static func run(rooms: () -> [RoomSummary], open: (String) -> Void, column: InfoColumn) async {
        // Unbuffered: piped, stdout is held back in a buffer, and a crash takes the buffer with it —
        // which is exactly when knowing how far it got matters.
        setvbuf(stdout, nil, _IONBF, 0)
        // `closed` measures with the info column shut, `open` with it open; whatever the user left
        // is put back before every way out — `exit` runs no `defer`.
        let wasOpen = CommandLine.arguments.contains("open") ? true : column.isOpen
        if CommandLine.arguments.contains("open") { column.isOpen = true }
        func leave(_ code: Int32) -> Never {
            column.isOpen = wasOpen
            // Written to disk before the process goes, or the user's choice is lost with it.
            UserDefaults.standard.synchronize()
            fflush(stdout)
            exit(code)
        }
        print("resize probe: waiting for the room list")
        for _ in 0..<60 where rooms().isEmpty {
            try? await Task.sleep(for: .milliseconds(250))
        }
        guard let first = rooms().first else {
            print("resize probe: no rooms")
            leave(1)
        }
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) else {
            print("resize probe: no window")
            leave(1)
        }
        print("resize probe: empty, least width \(window.minSize.width), content \(window.contentMinSize.width)")
        // Wide enough for anything before a chat opens, so that measuring the column cannot start the
        // very loop that is being measured.
        // `narrow`: the opposite — as narrow as the window goes before the chat opens, which is
        // what opening the column into a small window looks like.
        var wide = window.frame
        wide.size.width = CommandLine.arguments.contains("narrow") ? 0 : max(wide.width, 2000)
        window.setFrame(wide, display: true)
        try? await Task.sleep(for: .milliseconds(500))
        // `empty` leaves the column with no chat in it.
        if !CommandLine.arguments.contains("empty") {
            open(first.id)
            try? await Task.sleep(for: .seconds(3))
            if CommandLine.arguments.contains("closed") { column.isOpen = false }
            try? await Task.sleep(for: .seconds(1))
            print("resize probe: chat, least width \(window.minSize.width), content \(window.contentMinSize.width)")
        }
        if CommandLine.arguments.contains("toolbar") {
            try? await Task.sleep(for: .seconds(2))
            reportToolbar(of: window)
            leave(0)
        }
        let original = window.frame
        // At its narrowest, how wide each column is — which of them holds the window open.
        resize(window, to: 0, from: original)
        try? await Task.sleep(for: .milliseconds(500))
        for split in splitViews(in: window.contentView) {
            let widths = split.arrangedSubviews.map { Int($0.frame.width) }
            print("resize probe: at narrowest \(Int(window.frame.width)), columns \(widths)")
        }
        window.setFrame(original, display: true)
        await frame()
        let narrowest = window.minSize.width
        var steps = 0
        for pass in 0..<passes {
            print("resize probe: pass \(pass + 1)")
            var width = original.width
            // Narrower to the least the window allows, then wider, then back.
            while width > narrowest {
                width -= step
                resize(window, to: width, from: original); steps += 1
                await frame()
            }
            while width < original.width + reach {
                width += step
                resize(window, to: width, from: original); steps += 1
                await frame()
            }
        }
        window.setFrame(original, display: true)
        try? await Task.sleep(for: .milliseconds(500))
        print("resize probe: survived \(steps) steps")
        leave(0)
    }

    private static func resize(_ window: NSWindow, to width: CGFloat, from original: NSRect) {
        var frame = window.frame
        frame.size.width = width
        frame.origin.x = original.origin.x
        window.setFrame(frame, display: true)
    }

    /// `toolbar`: where each toolbar button stands, against where the columns are — whether the
    /// info column's buttons are over the column or over the conversation.
    private static func reportToolbar(of window: NSWindow) {
        for split in splitViews(in: window.contentView) {
            let edges = split.arrangedSubviews.map { view in
                let frame = view.convert(view.bounds, to: nil)
                return "\(Int(frame.minX))…\(Int(frame.maxX))"
            }
            print("toolbar probe: columns \(edges)")
        }
        print("toolbar probe: window \(Int(window.frame.width)), \(splitViews(in: window.contentView).count) split views")
        for item in window.toolbar?.items ?? [] {
            var place = "no view"
            if let view = item.view, view.window != nil {
                let frame = view.convert(view.bounds, to: nil)
                place = "\(Int(frame.minX))…\(Int(frame.maxX))"
            }
            print("toolbar probe: item \(item.itemIdentifier.rawValue) [\(item.label)] \(place)")
        }
        guard let frameView = window.contentView?.superview else { return }
        for button in buttons(in: frameView) {
            let frame = button.convert(button.bounds, to: nil)
            let name = button.accessibilityLabel() ?? button.toolTip ?? (button as? NSButton)?.title ?? "?"
            print("toolbar probe: button \(name) at \(Int(frame.minX))…\(Int(frame.maxX)), y \(Int(frame.minY))")
        }
    }

    private static func buttons(in view: NSView) -> [NSView] {
        let own: [NSView] = (view is NSButton || view.accessibilityRole() == .button) && view.frame.height < 60 ? [view] : []
        return own + view.subviews.flatMap { buttons(in: $0) }
    }

    private static func splitViews(in view: NSView?) -> [NSSplitView] {
        guard let view else { return [] }
        let own = (view as? NSSplitView).map { [$0] } ?? []
        return own + view.subviews.flatMap { splitViews(in: $0) }
    }

    private static func frame() async {
        try? await Task.sleep(for: .milliseconds(16))
    }
}
#endif
