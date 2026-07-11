import SwiftUI
import IskraFeatures

/// The app shell, shared by iPhone, iPad and Mac.
///
/// It is this short on purpose. Everything the app *does* lives in the packages;
/// this target exists only to own the bundle, the entitlements and the extensions.
/// If logic starts accumulating here, it belongs in `IskraFeatures` instead — that
/// is the code all three platforms share.
@main
struct IskraApp: App {
    init() {
        // `Iskra --verify-storage` answers the one question the test suite cannot:
        // whether this signed build actually has the App Group and the Keychain group
        // it claims. See StorageCheck.
        if StorageCheck.wasRequested {
            StorageCheck.runAndExit()
        }
    }

    var body: some Scene {
        WindowGroup {
            IskraRootView()
        }
        #if os(macOS)
        // A messenger is a content window, not a document: one window, resizable,
        // with the sidebar doing the navigating.
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1000, height: 700)
        #endif
    }
}
