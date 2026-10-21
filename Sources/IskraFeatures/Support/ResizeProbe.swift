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
        // `closed` measures with the info column shut; whatever the user left is put back.
        let wasOpen = column.isOpen
        defer { column.isOpen = wasOpen }
        print("resize probe: waiting for the room list")
        for _ in 0..<60 where rooms().isEmpty {
            try? await Task.sleep(for: .milliseconds(250))
        }
        guard let first = rooms().first else {
            print("resize probe: no rooms")
            exit(1)
        }
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) else {
            print("resize probe: no window")
            exit(1)
        }
        print("resize probe: empty, least width \(window.minSize.width), content \(window.contentMinSize.width)")
        // `empty` leaves the column with no chat in it.
        if !CommandLine.arguments.contains("empty") {
            open(first.id)
            try? await Task.sleep(for: .seconds(3))
            if CommandLine.arguments.contains("closed") { column.isOpen = false }
            try? await Task.sleep(for: .seconds(1))
            print("resize probe: chat, least width \(window.minSize.width), content \(window.contentMinSize.width)")
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
        column.isOpen = wasOpen
        exit(0)
    }

    private static func resize(_ window: NSWindow, to width: CGFloat, from original: NSRect) {
        var frame = window.frame
        frame.size.width = width
        frame.origin.x = original.origin.x
        window.setFrame(frame, display: true)
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
