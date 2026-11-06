import Foundation
import MatrixRustSDK

/// Whether a push can reach this device, asked of the two parties that decide it.
///
/// "Notifications do not arrive" has four causes that look identical from the lock screen: the
/// server has no pusher for this device, the pusher points at the wrong gateway or the wrong app id,
/// the gateway does not answer, or APNs refuses the token (a development token sent to production,
/// or the other way round, or a topic that is not the bundle ID). `PushRegistration.register` logs
/// nothing when it succeeds, so the log cannot tell them apart either. This asks the homeserver for
/// the pushers it holds, and then asks the gateway to deliver one push to each of ours — Sygnal
/// answers with the pushkeys APNs refused, which is the only place that last cause is ever said.
///
/// The FFI has no `getPushers`, and `getUrl` goes out without the access token (see
/// `DeviceListProbe`), so the listing is a plain request carrying the token from `Client.session()`.
/// The token is held for that one request and never printed. It goes **direct**, not through the
/// bridge: a probe that only works where the homeserver is reachable says so in its failure.
public enum PusherProbe {
    public struct Pusher: Sendable {
        public let appID: String
        /// Enough of the pushkey to tell two devices apart, and no more: the whole one names this
        /// phone to Apple, and the probe's output is the kind of thing that gets pasted somewhere.
        public var pushkeyPrefix: String { String(pushkey.prefix(8)) + "…" }
        public let url: String?
        public let format: String?
        public let deviceName: String
        public let lang: String
        /// Whether this is one this build would have registered: our app id and our gateway.
        public var isOurs: Bool { appID == PushRegistration.appID && url == PushRegistration.gatewayURL }

        let pushkey: String
    }

    public enum Listing: Sendable {
        case notSignedIn
        case pushers([Pusher])
        case refused(String)
    }

    public enum Delivery: Sendable {
        /// The gateway took the push and APNs did not refuse the token. If nothing appears on the
        /// phone now, the gateway and the token are not the reason.
        case accepted
        /// APNs refused this token — a sandbox token sent to production or the reverse, or a topic
        /// that is not this app's bundle ID. Sygnal's log has APNs's own word for which.
        case rejected
        case refused(String)
    }

    /// What this build registers as, for the caller to print beside what the server holds.
    public static var expectedAppID: String { PushRegistration.appID }
    public static var expectedGateway: String? { PushRegistration.gatewayURL }

    public static func list() async -> Listing {
        guard let client = try? await AuthenticationService().restoreClient() else {
            return .notSignedIn
        }

        let token: String
        let homeserver: String
        do {
            let session = try client.session()
            token = session.accessToken
            homeserver = session.homeserverUrl
        } catch {
            return .refused("the session would not say its token: \(error)")
        }

        // Joined with `appending(path:)`, not by hand — see `DeviceListProbe` for the 404 that a
        // doubled slash produces and how convincingly it reads as a refusal.
        guard let url = URL(string: homeserver)?.appending(path: "_matrix/client/v3/pushers") else {
            return .refused("the homeserver is not a URL: \(homeserver)")
        }

        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                return .refused("HTTP \(status): \(String(data: data, encoding: .utf8)?.prefix(300) ?? "")")
            }
            let body = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let entries = body?["pushers"] as? [[String: Any]] ?? []
            return .pushers(entries.map { entry in
                let data = entry["data"] as? [String: Any]
                return Pusher(appID: entry["app_id"] as? String ?? "?",
                              url: data?["url"] as? String,
                              format: data?["format"] as? String,
                              deviceName: entry["device_display_name"] as? String ?? "",
                              lang: entry["lang"] as? String ?? "",
                              pushkey: entry["pushkey"] as? String ?? "")
            })
        } catch {
            return .refused(Log.describe(error))
        }
    }

    /// Asks the gateway to deliver one push to this pusher, as the homeserver would.
    ///
    /// It arrives. The extension finds no such event, cannot decrypt it, and shows the plain
    /// fallback — which on the phone is the proof that the whole way down works.
    public static func deliver(to pusher: Pusher) async -> Delivery {
        guard let address = pusher.url, let url = URL(string: address) else {
            return .refused("this pusher names no gateway")
        }

        let notification: [String: Any] = [
            "notification": [
                "event_id": "$iskra-probe",
                "room_id": "!iskra-probe:invalid",
                "counts": ["unread": 1],
                "devices": [[
                    "app_id": pusher.appID,
                    "pushkey": pusher.pushkey,
                    "data": ["format": pusher.format ?? "event_id_only"],
                ]],
            ],
        ]

        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: notification)
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                return .refused("HTTP \(status): \(String(data: data, encoding: .utf8)?.prefix(300) ?? "")")
            }
            let body = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let rejected = body?["rejected"] as? [String] ?? []
            return rejected.contains(pusher.pushkey) ? .rejected : .accepted
        } catch {
            return .refused(Log.describe(error))
        }
    }
}
