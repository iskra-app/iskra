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
    /// Where the homeserver should send pushes.
    ///
    /// Our own Sygnal, because the public one at matrix.org only accepts app ids registered with
    /// them. It holds this app's APNs key and is the only thing in the chain that talks to Apple:
    /// the homeserver talks to it, it talks to APNs, and what comes back down to the device is a
    /// room id and an event id. How it was stood up — the key, the container, the certificate, the
    /// nginx in front — is in `docs/PUSH-GATEWAY.md`.
    ///
    /// Still an `Optional`, and the `guard` below still stands. Not because this is expected to go
    /// away, but because a gateway that is down is a thing that happens, and the shape that says
    /// "there may be nowhere to send this" is the shape that logs a line instead of crashing.
    ///
    /// Held here rather than in `AppSettings` because it is not a preference. Nobody chooses it,
    /// and an app that let somebody type a push gateway in would be an app that lets somebody be
    /// talked into typing one in.
    public static let gatewayURL: String? = "https://push.iskra.wtf/_matrix/push/v1/notify"

    /// The app id the gateway knows this app by — the name of an entry in its `sygnal.yaml`, and
    /// the only thing that tells the gateway *which* APNs to talk to.
    ///
    /// It is spelled after the **bundle id** — not the App Group and not the Keychain group, which
    /// are two other identifiers in this project that look just like it and are the easiest thing
    /// in the world to put here by mistake. A wrong one is a push APNs silently discards.
    ///
    /// Two of them, and this is not tidiness. A token minted for a build signed with
    /// `aps-environment: development` exists in the APNs **sandbox**; one from TestFlight or the
    /// App Store exists in **production**; and the two are separate worlds that do not know each
    /// other's tokens. The gateway holds one APNs key and has to be told which door to knock on,
    /// which it takes from the app id. One entry for both would mean push working in development
    /// and then stopping dead on the first TestFlight build — with no error anywhere on this side,
    /// because there is none: the token is valid, the call succeeds, and Apple drops the push.
    ///
    /// The gateway's `topic` stays the plain bundle id in both entries. That one really is the
    /// bundle id, and there is only one of those.
    #if DEBUG
    static let appID = "wtf.iskra.dev"
    #else
    static let appID = "wtf.iskra"
    #endif

    private let client: Client

    /// Which account on this device the pushes are for, written into every one of them — see
    /// `accountKey`. Nil only for a registration nobody on the device could be told apart from.
    private let accountID: String?

    init(client: Client, accountID: String? = nil) {
        self.client = client
        self.accountID = accountID
    }

    /// The key, beside `aps`, that names the account a push belongs to.
    ///
    /// A Matrix push says which room and which event, and nothing about *whose* — which was fine
    /// while there was one account, and with two is a push the extension cannot decrypt without
    /// guessing: two people on one phone can share a room. The value is the account's random session
    /// ID and never the Matrix ID, so neither the gateway nor Apple learns who is signed in here.
    /// The gateway sends `default_payload` along untouched, which is what carries it.
    public static let accountKey = "iskra_account"

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
                                                 defaultPayload: Self.defaultPayload(accountID: accountID))),
                appDisplayName: "Iskra",
                deviceDisplayName: deviceName,
                profileTag: nil,
                // Which language the *server* should write its fallback text in — the "New message"
                // that appears if the extension is killed before it can decrypt anything. The
                // extension's own words are localized on the device; this is the one sentence the
                // server writes, and it may as well be in the reader's language.
                lang: Locale.current.language.languageCode?.identifier ?? "en",
                // True, and the reason is the second account. The server keys a pusher on the app ID,
                // the pushkey *and the user*, so this account's own pusher is updated in place either
                // way — what `false` adds is deleting the pushers other users have with the same
                // app ID and pushkey. Two accounts on one phone on one homeserver share both, so
                // `false` meant signing in the second one quietly switched off the first one's
                // notifications.
                append: true
            )
        } catch {
            Log.push.error("the server would not take our push token: \(Log.describe(error), privacy: .public)")
        }
    }

    /// The shell of the notification, written once at registration and reused for every push.
    ///
    /// This was `nil`, and `nil` here means *nothing arrives*. `format: .eventIdOnly` tells the
    /// gateway to send no content, and a gateway with no content and no default payload sends a
    /// data-only push: an `aps` with neither `alert` nor `mutable-content`. iOS shows such a push
    /// nothing at all, and — this is the part that costs an afternoon — it does not run the
    /// notification service extension either. The extension is only woken for a push that already
    /// *is* a notification; its job is to rewrite one, not to conjure one. So the whole decryption
    /// path sat there, correct and never called, while the gateway logged `200` and Apple accepted
    /// every push.
    ///
    /// Hence two keys, and both are load-bearing:
    ///
    /// - `mutable-content: 1` — the permission for the extension to run at all.
    /// - `alert` with a `title` *and* a `body` — what makes this a notification rather than a
    ///   silent push. Both halves: an alert with only a body does not reliably wake the extension.
    ///
    /// The words are the server's fallback, and they are the ones already written for the locked
    /// screen — "Iskra", "Новое сообщение" — because it is the same sentence for the same reason:
    /// that something arrived, and nothing more. When the extension runs it replaces all of this
    /// before anybody sees it; when it cannot, this is what is shown, and it is the one line of a
    /// notification this app does not write on the device.
    ///
    /// Localized here, at registration, because this is the last place that knows the reader's
    /// language: afterwards the sentence lives on a homeserver and is handed to the gateway the
    /// same way for every push that follows. The `lang:` argument above tells the server the same
    /// thing, and this is that promise actually kept.
    static func defaultPayload(accountID: String? = nil) -> String? {
        var payload: [String: Any] = [
            "aps": [
                "mutable-content": 1,
                "alert": [
                    "title": AppLanguage.resolve(CoreStrings.Push.hiddenTitle),
                    "body": AppLanguage.resolve(CoreStrings.Push.hiddenBody)
                ]
            ]
        ]
        if let accountID {
            payload[accountKey] = accountID
        }

        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else {
            // Two constant strings and a dictionary literal; there is no input here to be
            // malformed. Said out loud anyway, because the failure it would cause is silence.
            Log.push.error("the default push payload could not be built")
            return nil
        }

        return json
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
    ///
    /// "Best-effort" is what the timeout is *for*, and without one the words were not true. This is
    /// the first thing the sign-out does — before the session is torn down, because deleting the
    /// pusher is a request that needs the session to make it — so a homeserver that accepts the
    /// connection and then says nothing held the entire sign-out here, ahead of everything: no
    /// logout, no store cleared, no settings forgotten, no screen change. The user taps "Sign out"
    /// and the app sits there. `logout()` learned this lesson already (`AuthenticationService`);
    /// this call was standing in front of it, unbounded, and undoing it.
    public func unregister(deviceToken: Data) async {
        let pushkey = deviceToken.map { String(format: "%02x", $0) }.joined()

        do {
            try await withTimeout(Self.unregisterTimeout) { [client] in
                try await client.deletePusher(
                    identifiers: PusherIdentifiers(pushkey: pushkey, appId: Self.appID)
                )
            }
        } catch {
            Log.push.error("the server would not forget our push token: \(Log.describe(error), privacy: .public)")
        }
    }

    /// The same ten seconds `logout()` gets, and for the same reason: nobody may be kept signed in
    /// by a server thinking about a request whose answer does not change what happens next.
    private static let unregisterTimeout: Duration = .seconds(10)
}
