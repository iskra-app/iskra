import SwiftUI
import UserNotifications
import IskraCore

#if os(iOS)
import UIKit
#endif

/// Asking to send notifications, and catching the token that comes back.
///
/// Two things had to be somewhere and were nowhere, and the audit found the absence rather than a
/// bug: nothing in the project ever called `requestAuthorization`, and nothing ever called
/// `registerForRemoteNotifications`. Without the second there is no device token, and without a
/// device token `setPusher` has no argument — so the roadmap's "then it is one call" was describing
/// a call with nothing to make it with.
///
/// **When it is asked matters more than that it is asked.** Not at launch, on an empty sign-in
/// screen: "Iskra would like to send you notifications" in front of somebody who has no account,
/// no chats and nothing that could possibly notify them is a question about nothing, and it is
/// answered "no" — once, permanently, by a person who has been given no reason to say yes. It is
/// asked after the first successful sign-in, when there are conversations on the screen behind it
/// and the question means something.
///
/// The token is delivered by `UIApplication`, which speaks to a delegate and not to SwiftUI, so
/// there is an `NSObject` here. It carries no logic — it hands the bytes to `IskraCore` and forgets
/// them.
@MainActor
public final class PushPermission {
    public static let shared = PushPermission()

    /// The token APNs gave us, once it has. Held because it arrives on its own schedule: the
    /// registration is asynchronous and may well land before anybody is signed in, and the session
    /// that eventually wants it is not the object that was told.
    private var deviceToken: Data?

    /// The session to tell, once there is a token to tell it about. Held for the mirror case: the
    /// user signs in and *then* the token arrives.
    private var registration: PushRegistration?
    private var deviceName: String = ""

    private init() {}

    /// Asks the user, and — if they agree — asks APNs for a token.
    ///
    /// A refusal is not an error and is not reported: a person who does not want notifications has
    /// said so, and an app that complains about it is an app arguing with a decision it asked for.
    public func request() async {
        #if os(iOS)
        let centre = UNUserNotificationCenter.current()

        do {
            guard try await centre.requestAuthorization(options: [.alert, .sound, .badge]) else {
                return
            }
        } catch {
            Log.push.error("the notification permission could not be asked for: \(String(describing: error), privacy: .public)")
            return
        }

        // This is what produces a device token. It is *not* the same act as the permission above —
        // an app can be permitted to show notifications and never register for remote ones, which
        // is precisely the state this app was in: allowed to notify, and unreachable.
        UIApplication.shared.registerForRemoteNotifications()
        #endif
    }

    /// APNs answered. Called by the app delegate.
    public func received(deviceToken token: Data) {
        deviceToken = token

        guard let registration else { return }
        let name = deviceName
        Task { await registration.register(deviceToken: token, deviceName: name) }
    }

    /// Somebody signed in. If APNs has already answered, the server can be told now; if it has not,
    /// this is remembered until it does.
    public func signedIn(_ session: UserSession) {
        registration = session.pushes()
        deviceName = session.displayName

        guard let deviceToken else { return }
        let registration = session.pushes()
        let name = deviceName
        Task { await registration.register(deviceToken: deviceToken, deviceName: name) }
    }

    /// Somebody signed out. The server is told to stop pushing here — see
    /// `PushRegistration.unregister`, and note that this must happen *before* the session is torn
    /// down, because it is a request that needs the session to make it.
    public func signingOut(_ session: UserSession) async {
        guard let deviceToken else {
            registration = nil
            return
        }

        await session.pushes().unregister(deviceToken: deviceToken)
        registration = nil
    }
}
