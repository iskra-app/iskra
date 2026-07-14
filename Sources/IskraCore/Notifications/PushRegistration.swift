import Foundation
import MatrixRustSDK

/// Telling the homeserver where to send a push.
///
/// `ROADMAP.md` and `docs/PUSH-GATEWAY.md` both said the remaining work on push "is not written in
/// Xcode". That is true of Sygnal and false of everything else, and the audit caught it: there was
/// no `requestAuthorization`, no `registerForRemoteNotifications`, and no `setPusher` anywhere in
/// the project. Not "waiting on a URL" — *absent*. Without a device token there is nothing to give
/// a gateway even once one exists, so the sentence "then it is one call" was describing a call that
/// had nowhere to get its argument from.
///
/// This is that half. What is genuinely left is one string: the URL of a Sygnal that will talk to
/// APNs on this app's behalf. Until there is one, everything below runs — the permission is asked
/// for, the token arrives, it is remembered — and the final call is skipped with a line in the log
/// rather than a crash or a silent shrug.
///
/// ## What actually happens to a push
///
/// The homeserver does not talk to APNs. It talks to a *gateway*, and the gateway holds the app's
/// APNs key and does. So `setPusher` tells the server two things: the URL of the gateway, and the
/// device token to give it. What comes back down is a room ID and an event ID and nothing else —
/// see `PushDecoder`, which is the half that was written first because it is the half that does not
/// depend on any of this.
///
/// `format: .eventIdOnly` is not an optimisation. It is the instruction to the gateway — and
/// therefore to APNs, and therefore to Apple — to carry *no message content*. The default sends a
/// preview, which in an encrypted room would be a preview of ciphertext, and in an unencrypted one
/// would be the message itself handed to two companies that have no business with it. The whole
/// point of the notification extension is that the words are assembled on the device that is
/// allowed to read them.
public struct PushRegistration: Sendable {
    /// Where the homeserver should send pushes. Nil until a Sygnal exists — see
    /// `docs/PUSH-GATEWAY.md`, which is the whole of the work left.
    ///
    /// Held here rather than in `AppEnvironment` because it is the only thing in the app that is
    /// *missing* rather than merely configurable: when it becomes a string, push works, and nothing
    /// else changes.
    public static let gatewayURL: String? = nil

    /// The app id the gateway knows this app by. It is the **bundle id** — not the App Group and
    /// not the Keychain group, which are two other identifiers that look just like it and are the
    /// easiest thing in the world to put here by mistake. A wrong one is a push APNs silently
    /// discards.
    static let appID = "moscow.swag.iskra"

    private let client: Client

    init(client: Client) {
        self.client = client
    }

    /// Registers this device's APNs token with the homeserver.
    ///
    /// The token is bytes, and the gateway wants them as hex. It is not a secret — it names a
    /// device to Apple and nothing more — but it is not logged either, because it names *this*
    /// device and a log is a thing that gets pasted into bug reports.
    public func register(deviceToken: Data, deviceName: String) async {
        guard let url = Self.gatewayURL else {
            // The one thing genuinely left. Said out loud on every launch that gets this far, so
            // that "push does not work" is never again a mystery to be re-derived from first
            // principles: it does not work because there is nowhere to send it.
            Log.push.error("no push gateway is configured, so the server has nowhere to send a push")
            return
        }

        let pushkey = deviceToken.map { String(format: "%02x", $0) }.joined()

        do {
            try await client.setPusher(
                identifiers: PusherIdentifiers(pushkey: pushkey, appId: Self.appID),
                kind: .http(data: HttpPusherData(url: url,
                                                 // No message content, ever. See the note above.
                                                 format: .eventIdOnly,
                                                 defaultPayload: nil)),
                appDisplayName: "Iskra",
                deviceDisplayName: deviceName,
                profileTag: nil,
                // Which language the *server* should write its fallback text in — the "New message"
                // that appears if the extension is killed before it can decrypt anything. The
                // extension's own words are localized on the device; this is the one sentence the
                // server writes, and it may as well be in the reader's language.
                lang: Locale.current.language.languageCode?.identifier ?? "en",
                // False: replace any pusher already registered for this device rather than adding a
                // second one. Appending is for a device that wants pushes from two gateways, which
                // is not a thing this app does — and getting it wrong means every message arriving
                // twice.
                append: false
            )
        } catch {
            Log.push.error("the server would not take our push token: \(Log.describe(error), privacy: .public)")
        }
    }

    /// Tells the homeserver to stop sending pushes here.
    ///
    /// Called on the way out, and it has to be: a server that is never told goes on pushing this
    /// account's messages to a device that has been signed out of. The extension there wakes up,
    /// finds no session, and falls back to the server's own text — so somebody who left the app
    /// keeps getting "New message" notifications about conversations they can no longer open. The
    /// content never leaks, and the notifications never stop.
    ///
    /// Best-effort, like `logout()` beside it: a device that cannot reach the server on its way out
    /// still signs out locally, and a stale pusher on the server is a much smaller problem than
    /// keys left on a phone the user believes is signed out.
    public func unregister(deviceToken: Data) async {
        let pushkey = deviceToken.map { String(format: "%02x", $0) }.joined()

        do {
            try await client.deletePusher(
                identifiers: PusherIdentifiers(pushkey: pushkey, appId: Self.appID)
            )
        } catch {
            Log.push.error("the server would not forget our push token: \(Log.describe(error), privacy: .public)")
        }
    }
}
