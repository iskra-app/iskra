import Foundation

/// One request through the tunnel, to answer the only question the settings screen leaves open:
/// is there really a bridge at that address.
///
/// It exists because everything about this feature fails silently otherwise. A key with a typo in
/// it, a bridge that is not running, a bridge that will not serve this homeserver, relays that are
/// all down — from inside the app every one of them looks the same, which is a sign-in that spins.
/// This asks for `/_matrix/client/versions`, the smallest thing a Matrix server answers, and
/// reports which of those it was.
///
/// The same call backs `Iskra --probe-bridge`, so the button on the screen and the probe in the
/// terminal cannot disagree about the thing they both diagnose.
public enum BridgeCheck {
    public enum Outcome: Sendable, Equatable {
        /// The bridge answered and the homeserver behind it answered too.
        case reachable(milliseconds: Int)
        /// The bridge is there and will not serve this homeserver — its `ALLOWED_UPSTREAMS`.
        case refused
        /// No relay took the request. Nothing was published, so nothing was heard.
        case noRelay
        /// Published, and nobody answered: the wrong key, a bridge that is not running, or a
        /// closed bridge that has never been told about this device.
        case silent
        case failed(String)
    }

    /// - Parameter limit: shorter than the transport's own, on purpose. This is somebody standing
    ///   in front of the screen waiting for an answer, not a request that matters.
    public static func run(bridgeKey: Data,
                           relays: [URL],
                           homeserver: URL,
                           identity: TunnelIdentity = TunnelIdentity(),
                           limit: Duration = .seconds(20)) async -> Outcome {
        let bridge: NostrTunnelUpstream
        do {
            bridge = try NostrTunnelUpstream(bridgeKey: bridgeKey,
                                             relays: relays,
                                             keys: try identity.keypair(),
                                             homeserver: homeserver,
                                             limit: limit)
        } catch {
            return .failed(String(describing: error))
        }

        await bridge.start()
        defer { Task { await bridge.stop() } }

        let started = ContinuousClock.now
        do {
            let response = try await bridge.send(ProxiedRequest(method: "GET",
                                                                target: "/_matrix/client/versions"))
            let elapsed = Int(started.duration(to: .now) / .milliseconds(1))
            switch response.status {
            case 200: return .reachable(milliseconds: elapsed)
            case 403: return .refused
            default: return .failed("HTTP \(response.status)")
            }
        } catch NostrTunnelUpstream.Failure.noRelayConnected {
            return .noRelay
        } catch NostrTunnelUpstream.Failure.noAnswer {
            return .silent
        } catch {
            return .failed(String(describing: error))
        }
    }

    /// The same check, driven from what is in the settings rather than from arguments.
    ///
    /// `nil` when there is nothing to check — no address filled in — which the caller shows as its
    /// own thing rather than as a failure.
    public static func runFromSettings(homeserver: URL,
                                       defaults: UserDefaults = .standard) async -> Outcome? {
        guard let key = TunnelSettings.bridgeKey(defaults) else { return nil }
        return await run(bridgeKey: key, relays: TunnelSettings.relays(defaults), homeserver: homeserver)
    }
}
