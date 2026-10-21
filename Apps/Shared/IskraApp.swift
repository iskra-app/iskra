import SwiftUI
import UserNotifications
import IskraCore
import IskraFeatures
import IskraDesign

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

        // `Iskra --probe-push` lists this account's pushers and has the gateway deliver one push
        // to each of ours, which is where APNs's refusal of a token is ever said. See PushProbe.
        if PushProbe.wasRequested {
            PushProbe.runAndExit()
        }

        // `Iskra --probe-bridge [npub] [homeserver]` sends one request through the nostr tunnel
        // and says which of the five identical-looking failures it was. See BridgeProbe.
        if BridgeProbe.wasRequested {
            BridgeProbe.runAndExit()
        }

        // `Iskra --probe-notification <roomID> <eventID>` decrypts one event the way the
        // notification extension will. A push carries nothing but those two identifiers, so
        // this needs no push gateway to be honest — see NotificationProbe, and ROADMAP stage 7.
        if NotificationProbe.wasRequested {
            NotificationProbe.runAndExit()
        }

        #endif

        #if os(macOS)
        // One copy of the app at a time. A second one — Xcode's build beside `run.sh`'s, the same
        // bundle ID twice — shares the store, the Keychain and the refresh token with the first, and
        // the two refreshing it in turn is how accounts used to vanish. So the second one hands over
        // to the first and goes. See `AppEnvironment.processName`.
        let me = ProcessInfo.processInfo.processIdentifier
        if let bundleID = Bundle.main.bundleIdentifier,
           let other = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
               .first(where: { $0.processIdentifier != me }) {
            other.activate()
            exit(0)
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
        mainWindow
        #if os(macOS)
        // "About Iskra" in the application menu opens the app's own About screen — see `AboutWindow`.
        AboutWindow()
        #endif
    }

    private var mainWindow: some Scene {
        WindowGroup {
            IskraRootView()
            // The one probe that cannot run from `init` above: it asks UIKit questions UIKit
            // does not answer truthfully until the app has finished launching. See IconProbe.
            #if DEBUG && os(iOS)
                .task {
                    if IconProbe.wasRequested {
                        await IconProbe.runAndExit()
                    }
                }
            #endif
        }
        #if os(macOS)
        // A messenger is a content window, not a document: one window, resizable,
        // with the sidebar doing the navigating.
        .windowResizability(.contentMinSize)
        // As wide as it can be narrow: both side columns and the narrowest conversation between them.
        .defaultSize(width: Theme.Size.windowMinimum, height: 700)
        .commands { AboutCommand() }
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
    ///
    /// ## Why the completion-handler form, and not `async`
    ///
    /// These two were written as `nonisolated … async`, which compiles and is wrong. The delegate
    /// requirement is not main-actor isolated, so an `async` implementation of it is free to be
    /// resumed on the generic executor — and what it carries there is a `UNNotificationResponse`,
    /// a UserNotifications object that is not `Sendable` and whose whole graph belongs to the main
    /// thread. Reading it from another one is a data race, and a data race on the path that runs
    /// *while the app is launching from a tap* is a crash on exactly the tap that started the app.
    ///
    /// In this form nothing crosses a thread but a `String`: `userInfo` is read synchronously, on
    /// the thread the system called us on, and only the room id goes to the main actor.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let roomID = info["room_id"] as? String
        let accountID = info[PushRegistration.accountKey] as? String

        if let roomID {
            Task { @MainActor in PushRouter.shared.tapped(roomID: roomID, accountID: accountID) }
        }

        // Called straight away rather than from inside the hop: the system is waiting on it, and
        // what it is waiting for — opening a conversation — is this app's business, not its own.
        completionHandler()
    }

    /// A push arrived while the app is in front. Without this iOS shows nothing at all, and
    /// somebody reading one conversation never learns that another one has said something.
    ///
    /// Answered synchronously, because the answer is the whole of what the system is asking for.
    /// `assumeIsolated` rather than a hop: this is delivered on the main thread, and saying so out
    /// loud means that if it ever is not, we find out at once instead of racing quietly.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let roomID = notification.request.content.userInfo["room_id"] as? String
        let accountID = notification.request.content.userInfo[PushRegistration.accountKey] as? String
        let options = MainActor.assumeIsolated {
            PushRouter.shared.presentation(forRoomID: roomID, accountID: accountID)
        }
        completionHandler(options)
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        // Ordinary on a simulator, which has no APNs at all, and worth a line on a device — where
        // it is the difference between "push is broken" and "push never started".
        Log.push.error("APNs would not register this device: \(String(describing: error), privacy: .public)")
    }
}
#endif
