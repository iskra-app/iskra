import Foundation

/// One request through the bridge, to answer the only question the settings screen leaves open:
/// is there really a bridge at that address.
///
/// It exists because everything about this feature fails silently otherwise. A key with a typo in
/// it, a bridge that is not running, a bridge that will not serve this homeserver, relays that are
/// all down — from inside the app every one of them looks the same, which is a sign-in that spins.
/// This asks for `/_matrix/client/versions`, the smallest thing a Matrix server answers, and
/// reports which of those it was.
///
/// It travels exactly as the SDK does: a `URLSession` through the same kind of `CONNECT` listener,
/// over nostr streams, with TLS to the homeserver end to end. So a bridge that passes this passes
/// for the SDK, and the reason a refused stream gives is the bridge's own word for it.
///
/// The same call backs `Iskra --probe-bridge`, so the button on the screen and the probe in the
/// terminal cannot disagree about the thing they both diagnose.
public enum BridgeCheck {
    public enum Outcome: Sendable, Equatable {
        /// The bridge answered and the homeserver behind it answered too.
        case reachable(milliseconds: Int)
        /// The bridge is there and will not take this device to this homeserver: not on its list,
        /// not a Matrix server, not on the public internet, not port 443.
        case refused
        /// No relay took the request. Nothing was published, so nothing was heard.
        case noRelay
        /// Published, and nobody answered: the wrong key, a bridge that is not running, or a
        /// closed bridge that has never been told about this device.
        case silent
        case failed(String)
    }

    /// The `rst` reasons that mean "the bridge will not take you there" — as opposed to a bridge
    /// that is busy, or a stream that broke on the way.
    static let refusals: Set<String> = [StreamReason.notAllowed, StreamReason.notMatrix,
                                        StreamReason.badPort, StreamReason.notPublic,
                                        StreamReason.noSuchHost]

    /// - Parameter limit: shorter than the SDK's own, on purpose. This is somebody standing in front
    ///   of the screen waiting for an answer, not a request that matters.
    public static func run(bridgeKey: Data,
                           relays: [URL],
                           homeserver: URL,
                           identity: TunnelIdentity = TunnelIdentity(),
                           limit: Duration = .seconds(20)) async -> Outcome {
        let streams: NostrStreamTunnel
        do {
            streams = try NostrStreamTunnel(bridgeKey: bridgeKey, relays: relays, keys: try identity.keypair())
        } catch {
            return .failed(String(describing: error))
        }
        await streams.start()
        let connect = LocalConnectProxy(upstream: streams)
        defer {
            Task {
                await connect.stop()
                await streams.stop()
            }
        }
        do {
            try await connect.start()
        } catch {
            return .failed(String(describing: error))
        }
        return await check(through: connect, homeserver: homeserver, limit: limit,
                           heard: streams.heard, relays: { await streams.connectedRelays() })
    }

    /// The request itself, through a listener already up — what the tests drive with a `DirectPipe`
    /// in place of the bridge and a `delegate` that trusts their homeserver.
    static func check(through connect: LocalConnectProxy,
                      homeserver: URL,
                      limit: Duration,
                      delegate: URLSessionDelegate? = nil,
                      heard: Heard? = nil,
                      relays: @Sendable () async -> Int = { 1 }) async -> Outcome {
        guard let url = URL(string: "/_matrix/client/versions", relativeTo: homeserver)?.absoluteURL else {
            return .failed("bad homeserver address")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = Double(limit.components.seconds)
        let session = await connect.urlSession(delegate: delegate)
        defer { session.finishTasksAndInvalidate() }

        let started = ContinuousClock.now
        do {
            let (_, response) = try await session.data(for: request)
            let elapsed = Int(started.duration(to: .now) / .milliseconds(1))
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return status == 200 ? .reachable(milliseconds: elapsed) : .failed("HTTP \(status)")
        } catch {
            if let reason = heard?.lastReset {
                return refusals.contains(reason) ? .refused : .failed("bridge: \(reason)")
            }
            if await relays() == 0 { return .noRelay }
            if heard?.anything == false { return .silent }
            return .failed(error.localizedDescription)
        }
    }

    /// The same check, driven from what is in the settings rather than from arguments.
    ///
    /// `nil` when there is nothing to check — no address filled in — which the caller shows as its
    /// own thing rather than as a failure.
    public static func runFromSettings(homeserver: URL,
                                       defaults: UserDefaults = TunnelSettings.store) async -> Outcome? {
        guard let key = TunnelSettings.bridgeKey(defaults) else { return nil }
        return await run(bridgeKey: key, relays: TunnelSettings.relays(defaults), homeserver: homeserver)
    }
}
