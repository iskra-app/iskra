#if os(iOS)
import CallKit
import Foundation
import IskraCore
import IskraFeatures
import PushKit

/// `Iskra --probe-voip-token` and `Iskra --probe-callkit`: the two halves of ringing that only a
/// real device can answer.
///
/// Neither works in the simulator, and not because they are fussy: there is no APNs there, so
/// PushKit issues no token, and `CXProvider` accepts calls and draws nothing.
///
/// ## What each one is for
///
/// **`--probe-voip-token`** turns "calls do not ring" into a specific sentence. It registers a
/// `PKPushRegistry`, waits, and prints whether a token arrived and how long it is. A missing token
/// almost always means `voip` is not in `UIBackgroundModes` — which produces no error anywhere
/// else, in any log, on any screen. It then asks the homeserver for the account's pushers, because
/// **the FFI has no way to read them back**: there is `setPusher` and `getRawPushRules` and
/// nothing in between, so the only way to see what the server thinks it has is to ask it over
/// HTTP, which this does with the session's own token.
///
/// **`--probe-callkit`** reports a synthetic incoming call and ends it ten seconds later. It
/// proves the provider configuration, the ringtone and that this process is allowed to ring at
/// all, without needing somebody to call you.
enum VoIPProbe {
    static var tokenWasRequested: Bool {
        CommandLine.arguments.contains("--probe-voip-token")
    }

    static var callKitWasRequested: Bool {
        CommandLine.arguments.contains("--probe-callkit")
    }

    // MARK: - The token and the pushers

    static func runTokenAndExit() -> Never {
        print("Iskra VoIP token probe")
        SDKLogging.start()

        Task { @MainActor in
            VoIPPermission.shared.start()
        }

        Task { @MainActor in
            // PushKit answers within a second or two on a device that has network. Ten is
            // generous, and the answer after ten is "it is not going to".
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(500))
                if VoIPPermission.shared.hasToken { break }
            }

            guard let hex = VoIPPermission.shared.tokenHex else {
                print("  ❌ no VoIP token, after ten seconds.")
                print("     The overwhelmingly likely cause is that `voip` is missing from")
                print("     UIBackgroundModes in Apps/project.yml. Nothing else reports this:")
                print("     PKPushRegistry simply never calls didUpdate, with no error.")
                print("     (In the simulator there is no APNs at all, so this is expected there.)")
                exit(1)
            }

            print("  ✅ VoIP token: \(hex.count) hex characters")
            if hex.count != 64 {
                print("     ⚠️  64 is what an intact APNs token looks like. 96 means somebody has")
                print("        base64-decoded an already-hex token — see convert_device_token_to_hex")
                print("        in docs/PUSH-GATEWAY.md, which is the same trap in a new costume.")
            }

            guard let session = await CallProbe.restoredSession() else {
                print("  ⓘ nobody is signed in, so the pushers cannot be listed.")
                exit(0)
            }

            await listPushers(session: session)
            exit(0)
        }

        Task {
            try? await Task.sleep(for: .seconds(45))
            print("  ⏱  the probe never finished")
            exit(2)
        }

        dispatchMain()
    }

    /// What the homeserver thinks is registered for this account, over plain HTTP.
    ///
    /// Only the app ids and the format are printed. A pushkey names this device and a URL names
    /// the gateway; neither is a secret exactly, and neither belongs in output that gets pasted
    /// into a bug report.
    @MainActor
    private static func listPushers(session: UserSession) async {
        guard let (homeserver, token) = session.credentialsForProbe() else {
            print("  ⓘ could not reach the session's own credentials to list pushers.")
            return
        }

        guard let url = URL(string: "/_matrix/client/v3/pushers", relativeTo: homeserver) else { return }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pushers = document["pushers"] as? [[String: Any]] else {
                print("  ⓘ the server's answer about pushers was not what we expected.")
                return
            }

            print("  ⓘ pushers on this account: \(pushers.count)")
            for pusher in pushers {
                let appID = pusher["app_id"] as? String ?? "?"
                let format = (pusher["data"] as? [String: Any])?["format"] as? String ?? "(full)"
                print("     • \(appID)  format: \(format)")
            }
            print("     Two are expected: the ordinary one and the .voip one. Both event_id_only.")
        } catch {
            print("  ⓘ could not ask the server about pushers: \(error)")
        }
    }

    // MARK: - CallKit

    static func runCallKitAndExit() -> Never {
        print("Iskra CallKit probe — a synthetic call, ended after ten seconds")

        let configuration = CXProviderConfiguration()
        configuration.supportsVideo = true
        configuration.maximumCallsPerCallGroup = 1
        configuration.supportedHandleTypes = [.generic]

        let provider = CXProvider(configuration: configuration)
        let uuid = RingID.uuid(forEventID: "$probe")

        let update = CXCallUpdate()
        update.localizedCallerName = "Iskra probe"
        update.remoteHandle = CXHandle(type: .generic, value: "probe")
        update.hasVideo = false

        provider.reportNewIncomingCall(with: uuid, update: update) { error in
            if let error {
                print("  ❌ iOS would not show the call: \(error)")
                print("     A device in Do Not Disturb with this app not allowed through will say")
                print("     this, and so will one where the VoIP privilege has been withdrawn.")
                exit(1)
            }
            print("  ✅ the call was reported. The phone should be ringing now.")
        }

        Task {
            try? await Task.sleep(for: .seconds(10))
            provider.reportCall(with: uuid, endedAt: nil, reason: .remoteEnded)
            print("  ✅ and ended. If it rang and stopped, CallKit is working in this build.")
            exit(0)
        }

        dispatchMain()
    }
}
#endif
