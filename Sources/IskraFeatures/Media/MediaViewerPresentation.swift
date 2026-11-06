import SwiftUI
import IskraCore

#if os(macOS)
import AppKit
#endif

extension View {
    /// Opens the media viewer over everything: a cover with a clear background on the phone, so the
    /// conversation stays under it to be blurred (`GalleryBackdrop`), and a window of its own laid
    /// over the whole screen on the Mac (`MacMediaViewer`).
    ///
    /// One modifier for every place a photograph opens, so that it opens the same way from a
    /// bubble, a profile and a room's media.
    func mediaViewer<Item: Identifiable>(item: Binding<Item?>,
                                         content: @escaping (Item) -> MediaPager) -> some View {
        modifier(MediaViewerPresentation(item: item, content: content))
    }
}

private struct MediaViewerPresentation<Item: Identifiable>: ViewModifier {
    @Binding var item: Item?
    let content: (Item) -> MediaPager

    #if os(macOS)
    @Environment(\.mediaLoader) private var loader
    @Environment(\.locale) private var locale
    #endif

    func body(content view: Content) -> some View {
        #if os(iOS)
        view.fullScreenCover(item: $item) { item in
            content(item)
                // Clear, not black: the viewer draws its own backdrop out of the chat underneath,
                // and a background here would leave it nothing to blur.
                .presentationBackground(.clear)
        }
        #else
        view.onChange(of: item?.id, initial: true) { _, id in
            guard id != nil, let item else { return }
            let content = content
            // A window has no environment of its own; what the viewer reads is handed over.
            let loader = loader
            let locale = locale
            MacMediaViewer.open { onClose, topInset in
                AnyView(content(item)
                    .closing(with: onClose)
                    // The camera housing: the overlay covers the menu bar, and so the notch too.
                    .safeAreaPadding(.top, topInset)
                    .environment(\.mediaLoader, loader)
                    .environment(\.locale, locale))
            } onClosed: {
                self.item = nil
            }
        }
        #endif
    }
}

#if os(macOS)
extension MediaPager {
    /// The same viewer, told how to leave its window.
    fileprivate func closing(with onClose: @escaping () -> Void) -> MediaPager {
        var pager = self
        pager.onClose = onClose
        return pager
    }
}

/// The viewer on the Mac: a borderless window laid over the whole screen the conversation is on,
/// the menu bar and the Dock included — there is no `fullScreenCover` here, a sheet is a small card
/// over the conversation, and a full-screen space slides the whole desktop away to show one picture.
///
/// It is transparent, so the backdrop can blur what is really under it (`GalleryBackdrop`), and it
/// hides while the app is not active — a photograph over everything belongs to Iskra, not to the
/// app somebody has just switched to — and comes back when Iskra does.
@MainActor
final class MacMediaViewer: NSObject, NSWindowDelegate {
    /// Every viewer open now. A window delegate is held weakly; this is what keeps it alive until
    /// its window closes.
    private static var open: Set<MacMediaViewer> = []

    private let window: NSWindow
    private let onClosed: () -> Void
    private var isClosing = false

    private static let fade: TimeInterval = 0.18

    static func open(_ content: (_ onClose: @escaping () -> Void, _ topInset: CGFloat) -> AnyView,
                     onClosed: @escaping () -> Void) {
        let source = NSApp.keyWindow ?? NSApp.mainWindow
        guard let screen = source?.screen ?? NSScreen.main else {
            onClosed()
            return
        }
        let window = OverlayWindow(contentRect: screen.frame, styleMask: [.borderless],
                                   backing: .buffered, defer: false)
        let viewer = MacMediaViewer(window: window, onClosed: onClosed)
        window.contentView = NSHostingView(rootView: content({ [weak viewer] in viewer?.close() },
                                                             screen.safeAreaInsets.top))
        window.setFrame(screen.frame, display: false)
        open.insert(viewer)

        window.alphaValue = 0
        window.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = fade
            window.animator().alphaValue = 1
        }
    }

    private init(window: NSWindow, onClosed: @escaping () -> Void) {
        self.window = window
        self.onClosed = onClosed
        super.init()
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        // Over the menu bar and the Dock, which a picture opened "over everything" has to cover.
        window.level = .statusBar
        window.hidesOnDeactivate = true
        // And over a conversation that is itself in full screen.
        window.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        window.delegate = self
    }

    func close() {
        guard !isClosing else { return }
        isClosing = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fade
            window.animator().alphaValue = 0
        } completionHandler: { [window] in
            MainActor.assumeIsolated { window.close() }
        }
    }

    func windowWillClose(_ notification: Notification) {
        onClosed()
        Self.open.remove(self)
    }
}

/// A borderless window refuses to become key unless told otherwise — and without that, Escape,
/// the arrow keys and the cross's shortcut would all go to the window underneath.
private final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
#endif
