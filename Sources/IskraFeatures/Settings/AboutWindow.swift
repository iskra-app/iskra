#if os(macOS)
import SwiftUI
import IskraCore
import IskraDesign

/// "About Iskra" in the application menu, opening the app's own About screen in a window of its
/// own — the version, the build, the device, the links and the licences — instead of the system's
/// panel with an icon and a version number and nothing a bug report needs.
///
/// A window of its own scene, so it is there with nobody signed in as well, and it is dressed the
/// way the main window is: a separate scene inherits none of the root's environment, so the accent,
/// the language picked in Settings and light or dark are applied again here.
public struct AboutWindow: Scene {
    public static let id = "about"

    public init() {}

    public var body: some Scene {
        Window(Text(Strings.About.title), id: Self.id) {
            AboutWindowContent()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}

/// The menu item that opens it, in place of the system's.
public struct AboutCommand: Commands {
    @Environment(\.openWindow) private var openWindow

    public init() {}

    public var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button {
                openWindow(id: AboutWindow.id)
            } label: {
                Text(Strings.About.title)
            }
        }
    }
}

private struct AboutWindowContent: View {
    @AppStorage(AccentTheme.storageKey) private var accent: AccentTheme = .default
    @AppStorage(AppearanceMode.storageKey) private var appearance: AppearanceMode = .default

    var body: some View {
        NavigationStack {
            AboutView()
        }
        .frame(width: Theme.Size.aboutWindow.width, height: Theme.Size.aboutWindow.height)
        .environment(\.accent, accent)
        .environment(\.locale, AppLanguage.locale)
        .preferredColorScheme(appearance.colorScheme)
    }
}
#endif
