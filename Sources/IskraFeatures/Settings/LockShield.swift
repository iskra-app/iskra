import SwiftUI
import IskraCore
import IskraDesign
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Puts the lock's shield and the privacy cover over the whole app — sheets and full-screen
/// viewers included.
///
/// They used to be `.overlay`s at the root, and an overlay is part of the view it is attached to:
/// a `.sheet` or a `.fullScreenCover` is drawn by its own presentation controller *above* the root,
/// so it sat on top of both. The sheet with a freshly made recovery key, a photo opened full-screen,
/// in-room search — all of them readable in the app switcher and usable behind a Face ID prompt,
/// on a phone whose owner had asked the app to lock itself. So the two live in a window of their
/// own, above everything the app can present.
///
/// On the Mac there was a second gap: the title bar and the toolbar are AppKit's, drawn over the
/// SwiftUI content, so an overlay covered the chat and left the chat's name and every toolbar
/// button above it, there to be read and pressed. A window of its own covers those too.
extension View {
    func lockShield(appLock: AppLock, phase: ScenePhase, accent: AccentTheme,
                    colorScheme: ColorScheme?) -> some View {
        modifier(LockShieldModifier(appLock: appLock, phase: phase, accent: accent,
                                    colorScheme: colorScheme))
    }
}

private struct LockShieldModifier: ViewModifier {
    let appLock: AppLock
    let phase: ScenePhase
    let accent: AccentTheme
    let colorScheme: ColorScheme?

    #if os(macOS)
    /// Whether Iskra is the app in front. A Mac window that another app has been switched to stays
    /// on screen, readable, and its scene often stays `.active` all the while — so the phase alone
    /// left the conversation in plain view the whole time somebody was in another app.
    @State private var isAppActive = NSApp.isActive
    #else
    private let isAppActive = true
    #endif

    private var cover: Bool {
        PrivacyCover.isNeeded(lockEnabled: appLock.isEnabled, phase: phase, appIsActive: isAppActive)
    }

    func body(content: Content) -> some View {
        content
            .onAppear(perform: update)
            .onChange(of: appLock.isLocked) { update() }
            .onChange(of: cover) { update() }
            .onChange(of: accent) { update() }
            .onChange(of: colorScheme) { update() }
            #if os(macOS)
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
                isAppActive = false
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                isAppActive = true
            }
            #endif
    }

    /// Synchronous on purpose, like the cover itself: the switcher's photograph is taken while the
    /// app is `.inactive`, and a window that arrived a runloop late would be photographed absent.
    private func update() {
        if appLock.isLocked {
            ShieldWindows.shared.show(shield(LockScreen(appLock: appLock)))
        } else if cover {
            ShieldWindows.shared.show(shield(PrivacyCover()))
        } else {
            ShieldWindows.shared.hide()
        }
    }

    private func shield(_ view: some View) -> AnyView {
        AnyView(view
            .environment(\.accent, accent)
            .environment(\.appLock, appLock)
            .tint(.primary)
            .preferredColorScheme(colorScheme))
    }
}

#if os(iOS)
/// One shield window per scene — an iPad can have several windows of the app open, and a lock that
/// covered one of them would not be a lock.
@MainActor
private final class ShieldWindows {
    static let shared = ShieldWindows()

    private var windows: [ObjectIdentifier: UIWindow] = [:]
    /// Whichever window had the keyboard before the shield took it, to hand it back afterwards.
    private var previousKey: [ObjectIdentifier: UIWindow] = [:]

    func show(_ view: AnyView) {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        for scene in scenes {
            let id = ObjectIdentifier(scene)
            if let window = windows[id], let host = window.rootViewController as? UIHostingController<AnyView> {
                host.rootView = view
                continue
            }
            let host = UIHostingController(rootView: view)
            host.view.backgroundColor = .clear
            // VoiceOver stays inside the shield: the conversation behind it is not something to
            // read out on a locked app.
            host.view.accessibilityViewIsModal = true

            let window = UIWindow(windowScene: scene)
            window.windowLevel = .alert + 1
            window.rootViewController = host
            previousKey[id] = scene.keyWindow
            // Key as well as visible, so a hardware keyboard types into the shield and not into
            // whatever field was focused behind it.
            window.makeKeyAndVisible()
            windows[id] = window
        }
    }

    func hide() {
        for (id, window) in windows {
            window.isHidden = true
            previousKey[id]?.makeKey()
        }
        windows.removeAll()
        previousKey.removeAll()
    }
}
#endif

#if os(macOS)
/// A shield over every window the app has on screen, as a child window of each — so it moves with
/// it, goes into full screen with it, and covers its title bar and toolbar along with its content.
///
/// The conversation's window gets the screen itself (the padlock, the unlock button). Everything
/// else gets a plain opaque sheet: a sheet over the conversation, and in full screen the toolbar,
/// which AppKit moves into a window of its own (`NSToolbarFullScreenWindow`) and which would
/// otherwise show the chat's name above a covered chat.
@MainActor
private final class ShieldWindows {
    static let shared = ShieldWindows()

    /// The shield over each window, keyed by the window it covers.
    private var shields: [ObjectIdentifier: ShieldWindow] = [:]
    private var view: AnyView?
    /// Whichever window had the keyboard before the shield took it, to hand it back afterwards.
    private weak var previousKey: NSWindow?
    private var observers: [NSObjectProtocol] = []

    func show(_ view: AnyView) {
        if self.view == nil {
            previousKey = NSApp.keyWindow
            observe()
        }
        self.view = view
        cover()
    }

    func hide() {
        guard view != nil else { return }
        view = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        for shield in shields.values {
            shield.parent?.removeChildWindow(shield)
            shield.orderOut(nil)
        }
        shields.removeAll()
        previousKey?.makeKey()
        previousKey = nil
    }

    /// Puts a shield over every visible window that has none, refreshes the ones already up, and
    /// drops those whose window has gone.
    private func cover() {
        guard let view else { return }
        let windows = NSApp.windows.filter(Self.needsShield)
        let ids = Set(windows.map(ObjectIdentifier.init))
        for (id, shield) in shields where !ids.contains(id) {
            shield.parent?.removeChildWindow(shield)
            shield.orderOut(nil)
            shields[id] = nil
        }
        for window in windows {
            let primary = Self.isPrimary(window)
            let content = primary ? view : AnyView(ShieldBackground())
            if let shield = shields[ObjectIdentifier(window)] {
                (shield.contentView as? NSHostingView<AnyView>)?.rootView = content
                shield.setFrame(window.frame, display: true)
                continue
            }
            let shield = ShieldWindow(covering: window, titled: primary)
            shield.contentView = NSHostingView(rootView: content)
            window.addChildWindow(shield, ordered: .above)
            shields[ObjectIdentifier(window)] = shield
        }
        // The keyboard goes to the shield, so that typing reaches the lock and not the composer
        // that had the focus behind it.
        if NSApp.isActive, let shield = shields.values.first(where: { $0.canBecomeMain }), !shield.isKeyWindow {
            shield.makeKeyAndOrderFront(nil)
        }
    }

    /// While the shield is up: a window that comes on screen gets one too (a sheet, a window back
    /// from the Dock, the viewer that hid while the app was away), and a shield keeps its window's
    /// size — a child window follows its parent's moves, not its resizes.
    private func observe() {
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification,
                     NSWindow.didDeminiaturizeNotification, NSApplication.didBecomeActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { note in
                guard !(note.object is ShieldWindow) else { return }
                MainActor.assumeIsolated { ShieldWindows.shared.cover() }
            })
        }
        observers.append(center.addObserver(forName: NSWindow.didResizeNotification, object: nil,
                                            queue: .main) { note in
            guard let window = note.object as? NSWindow, !(window is ShieldWindow) else { return }
            let id = ObjectIdentifier(window)
            MainActor.assumeIsolated {
                guard let shield = ShieldWindows.shared.shields[id], let covered = shield.covered else { return }
                shield.setFrame(covered.frame, display: true)
            }
        })
    }

    private static func needsShield(_ window: NSWindow) -> Bool {
        guard window.isVisible, !(window is ShieldWindow) else { return false }
        // The system's own: menus, tooltips, the status bar. Nothing of anybody's in them.
        let name = String(describing: type(of: window))
        return !["Menu", "ToolTip", "StatusBar"].contains(where: name.contains)
    }

    /// The conversation's window itself, as opposed to a sheet on it or its toolbar in full screen.
    private static func isPrimary(_ window: NSWindow) -> Bool {
        window.sheetParent == nil && window.styleMask.contains(.titled)
            && window.standardWindowButton(.closeButton) != nil
    }
}

/// The window the shield is drawn in.
///
/// Over the conversation's window it is titled, with a transparent title bar, so its traffic lights
/// stand exactly where the window's own do — and they, and ⌘W and ⌘M, act on that window: a lock
/// that cannot be closed or put away until it is opened is a lock in the way, not a lock. Dragging
/// its title bar moves the window too. The green button is off; a shield cannot be resized apart
/// from what it covers.
private final class ShieldWindow: NSWindow {
    private(set) weak var covered: NSWindow?
    private let titled: Bool

    init(covering window: NSWindow, titled: Bool) {
        self.covered = window
        self.titled = titled
        super.init(contentRect: window.frame,
                   styleMask: titled ? [.titled, .closable, .miniaturizable, .fullSizeContentView] : [.borderless],
                   backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isMovable = false
        level = window.level
        appearance = window.appearance
        collectionBehavior = [.fullScreenAuxiliary]
        isOpaque = true
        backgroundColor = .windowBackgroundColor
        setFrame(window.frame, display: false)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { titled }

    override func performClose(_ sender: Any?) { covered?.performClose(sender) }
    override func performMiniaturize(_ sender: Any?) { covered?.performMiniaturize(sender) }

    override func sendEvent(_ event: NSEvent) {
        if titled, event.type == .leftMouseDown, event.locationInWindow.y > contentLayoutRect.maxY,
           !isOnTrafficLight(event.locationInWindow), let covered {
            covered.performDrag(with: event)
            return
        }
        super.sendEvent(event)
    }

    private func isOnTrafficLight(_ point: NSPoint) -> Bool {
        [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].contains { kind in
            guard let button = standardWindowButton(kind) else { return false }
            return button.convert(button.bounds, to: nil).contains(point)
        }
    }
}

/// What a window other than the conversation's wears under the shield: nothing at all, opaquely.
private struct ShieldBackground: View {
    var body: some View {
        Rectangle()
            .fill(.background)
            .ignoresSafeArea()
            .accessibilityHidden(true)
    }
}
#endif
