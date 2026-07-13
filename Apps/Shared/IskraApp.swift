import SwiftUI
import IskraCore
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
        // The SDK is silent until asked, and a signed build on a device has no debugger
        // attached — the log is the only witness to a sign-in that stalls. Capped at
        // .info, which is the last level that does not log message bodies.
        SDKLogging.start()

        // `Iskra --verify-storage` answers the one question the test suite cannot:
        // whether this signed build actually has the App Group and the Keychain group
        // it claims. See StorageCheck.
        if StorageCheck.wasRequested {
            StorageCheck.runAndExit()
        }

        // `Iskra --probe-signin <address>` drives the same lookup the Continue button
        // does, with the SDK's tracing on. See SignInProbe.
        if SignInProbe.wasRequested {
            SignInProbe.runAndExit()
        }

        // `Iskra --probe-devices` asks a signed-in homeserver for this account's sessions
        // through the only door the FFI leaves open. See DeviceProbe, and ROADMAP stage 6.
        if DeviceProbe.wasRequested {
            DeviceProbe.runAndExit()
        }

        // `Iskra --probe-notification <roomID> <eventID>` decrypts one event the way the
        // notification extension will. A push carries nothing but those two identifiers, so
        // this needs no push gateway to be honest — see NotificationProbe, and ROADMAP stage 7.
        if NotificationProbe.wasRequested {
            NotificationProbe.runAndExit()
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
