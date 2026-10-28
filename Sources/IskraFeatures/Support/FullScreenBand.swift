#if os(macOS)
import AppKit
import SwiftUI
import IskraDesign

extension View {
    /// Paints the toolbar's band in full screen the colour of the room list. Put once, at the root.
    func paintsFullScreenBand() -> some View {
        modifier(FullScreenBand())
    }
}

/// The band at the top of the screen in full screen, in the side columns' page colour.
///
/// In a window there is no band: the title bar is transparent and the columns run up under it. In
/// full screen AppKit moves the toolbar into a window of its own (`NSToolbarFullScreenWindow`) and
/// lays an opaque grey under each column's part of it (`NSTitlebarBackgroundView`), and nothing
/// SwiftUI says reaches it — `toolbarBackground` was tried and the band stayed the same grey, a
/// third colour between the room list and the chat. So a plain view of our own is laid over those
/// backgrounds and under the toolbar's items.
///
/// It finds AppKit's views by class name, and if they are ever renamed it finds nothing and does
/// nothing: the band goes back to the system's grey, which is a cosmetic loss and not a broken
/// window.
private struct FullScreenBand: ViewModifier {
    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in
                Self.paint()
            }
            // The toolbar's window can be rebuilt while in full screen — a toolbar item coming or
            // going does it — and the new one has no band.
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didUpdateNotification)) { note in
                guard let window = note.object as? NSWindow, Self.isToolbarWindow(window) else { return }
                Self.paint(window)
            }
            .onAppear { Self.paint() }
    }

    private static func isToolbarWindow(_ window: NSWindow) -> Bool {
        String(describing: type(of: window)) == "NSToolbarFullScreenWindow"
    }

    @MainActor private static func paint() {
        NSApp.windows.filter(isToolbarWindow).forEach(paint)
    }

    @MainActor private static func paint(_ window: NSWindow) {
        guard let root = window.contentView?.superview,
              let container = first(named: "NSTitlebarContainerView", in: root),
              !container.subviews.contains(where: { $0 is BandView }) else { return }
        let backgrounds = container.subviews.filter { String(describing: type(of: $0)) == "NSTitlebarBackgroundView" }
        guard let topmost = backgrounds.last else { return }
        let band = BandView(frame: container.bounds)
        band.autoresizingMask = [.width, .height]
        container.addSubview(band, positioned: .above, relativeTo: topmost)
    }

    private static func first(named name: String, in view: NSView) -> NSView? {
        if String(describing: type(of: view)) == name { return view }
        for subview in view.subviews {
            if let found = first(named: name, in: subview) { return found }
        }
        return nil
    }
}

/// The colour itself, redrawn when the appearance turns light or dark.
private final class BandView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { nil }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor(Color.groupedPage).cgColor
        }
    }

    /// Clicks go through to whatever is under the band — it is paint, not a control.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Not a handle to drag the window by. A view that is not opaque says it is one by default,
    /// and the window server takes a press in such a region for itself, before the app sees it:
    /// with the band over the whole bar, nothing on it could be pressed — the toolbar's buttons
    /// and the traffic lights alike — though `hitTest` above found every one of them.
    override var mouseDownCanMoveWindow: Bool { false }
}
#endif
