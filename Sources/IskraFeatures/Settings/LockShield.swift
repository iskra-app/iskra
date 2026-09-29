import SwiftUI
import IskraCore
import IskraDesign
#if os(iOS)
import UIKit
#endif

/// Puts the lock's shield and the privacy cover over the whole app — sheets and full-screen
/// viewers included.
///
/// They used to be `.overlay`s at the root, and an overlay is part of the view it is attached to:
/// a `.sheet` or a `.fullScreenCover` is drawn by its own presentation controller *above* the root,
/// so it sat on top of both. The sheet with a freshly made recovery key, a photo opened full-screen,
/// in-room search — all of them readable in the app switcher and usable behind a Face ID prompt,
/// on a phone whose owner had asked the app to lock itself. On iOS the two now live in a window of
/// their own, above everything the app can present.
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

    private var cover: Bool { PrivacyCover.isNeeded(lockEnabled: appLock.isEnabled, phase: phase) }

    func body(content: Content) -> some View {
        #if os(iOS)
        content
            .onAppear(perform: update)
            .onChange(of: appLock.isLocked) { update() }
            .onChange(of: cover) { update() }
            .onChange(of: accent) { update() }
            .onChange(of: colorScheme) { update() }
        #else
        // A Mac sheet is a window of its own too, but there is no app switcher photographing it,
        // and the shield over the main window still stands between a passer-by and the app.
        content
            .overlay {
                if cover { PrivacyCover() }
            }
            .animation(nil, value: phase)
            .overlay {
                if appLock.isLocked {
                    LockScreen(appLock: appLock)
                        .transition(.opacity)
                }
            }
            .animation(.smooth(duration: Theme.Timing.chrome), value: appLock.isLocked)
        #endif
    }

    #if os(iOS)
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
    #endif
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
