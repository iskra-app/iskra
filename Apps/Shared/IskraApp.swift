import SwiftUI
import UserNotifications
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

        // The probes, and they are compiled *out* of a release build entirely.
        //
        // They were not, and one of them prints decrypted message bodies to standard output —
        // `--probe-notification`, whose whole job is to show what would land on a lock screen, and
        // which cannot do that job without showing it. Guarded by nothing but a command-line flag,
        // that is a released binary in which anybody who can start the app with an argument can
        // read the user's messages out of the console; and on a device, `print` goes to the unified
        // log, which — unlike `Logger` — does not redact anything.
        //
        // The flag was never the protection. `#if DEBUG` is: the code, the strings and the ability
        // are not in the shipped app at all. Every command in `CLAUDE.md` builds Debug, so nothing
        // about how these are run changes.
        #if DEBUG
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
        #endif
    }

    #if os(iOS)
    /// APNs hands a device token to a `UIApplicationDelegate` and to nothing else — there is no
    /// SwiftUI door for it, and the same is true of a tap on a banner. So there is a delegate, and
    /// it forwards: it catches the bytes and the taps and hands them to `IskraFeatures`, which is
    /// where the decisions about what to do with them live.
    @UIApplicationDelegateAdaptor(PushDelegate.self) private var pushDelegate
    #endif

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

#if os(iOS)
/// The two things `UIApplication` still has to be asked for by hand: the device token, and what a
/// tap on a notification means.
///
/// It decides nothing. Both of those go straight to `IskraFeatures` — `PushPermission` for the
/// token, `PushRouter` for the tap — because this target owns the bundle and the entitlements and
/// is meant to stay this short.
final class PushDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Has to happen here. A delegate set any later than "the app has finished launching" is a
        // delegate iOS has already given up asking, and the tap that *started* the app — the one
        // most worth acting on — is delivered to nobody.
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in
            PushPermission.shared.received(deviceToken: deviceToken)
        }
    }

    /// Somebody tapped the banner. The room id is the one thing the extension put in `userInfo`,
    /// and it is the whole of what is needed: see `PushRouter`.
    // `nonisolated` because the delegate protocol is main-actor isolated and neither a
    // `UNNotification` nor the centre itself is `Sendable` — so an implementation that inherited
    // that isolation could not be handed its own arguments. The room id is a `String`; it crosses
    // to the main actor on its own.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        guard let roomID = response.notification.request.content.userInfo["room_id"] as? String else {
            return
        }
        await MainActor.run { PushRouter.shared.tapped(roomID: roomID) }
    }

    /// A push arrived while the app is in front. Without this iOS shows nothing at all, and
    /// somebody reading one conversation never learns that another one has said something.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        let roomID = notification.request.content.userInfo["room_id"] as? String
        return await MainActor.run { PushRouter.shared.presentation(forRoomID: roomID) }
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        // Ordinary on a simulator, which has no APNs at all, and worth a line on a device — where
        // it is the difference between "push is broken" and "push never started".
        Log.push.error("APNs would not register this device: \(String(describing: error), privacy: .public)")
    }
}
#endif
