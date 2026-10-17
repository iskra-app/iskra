import Foundation
import MatrixRustSDK
import Testing
@testable import IskraCore

/// The blind route, driven by the real SDK: a client built with the homeserver's own `https`
/// address and `LocalConnectProxy` as its proxy, against a homeserver behind real TLS.
///
/// The question is the one the blind bridge stands or falls on: does *everything* go through the
/// proxy? A request that went around it would, with a bridge, be a request that went around the
/// bridge — the quiet direct connection this app refuses to make. So the homeserver's listener
/// records the far-end port of every connection it is handed, the pipe records the port of every
/// connection it made, and the first list must be inside the second: sign-in, sliding sync, media,
/// and the client the notification extension builds.
@MainActor
@Suite("Blind route", .serialized)
struct BlindRouteTests {
    private struct Rig {
        let homeserver: LocalHTTPProxy
        let address: String
        let connect: LocalConnectProxy
        let route: AuthenticationService.FixedRoute
        let environment: AppEnvironment
        let sessionStore: SessionStore

        func authentication() -> AuthenticationService {
            AuthenticationService(environment: environment, sessionStore: sessionStore, fixedRoute: route)
        }

        func stop() async {
            await connect.stop()
            await homeserver.stop()
        }
    }

    private func rig(upstream: ConnectUpstream, heard: Heard? = nil) async throws -> Rig {
        let tls = try TestTLS.make()
        let homeserver = LocalHTTPProxy(upstream: MockHomeserver(), tls: tls.identity)
        let port = try await homeserver.start()
        let connect = LocalConnectProxy(upstream: upstream)
        try await connect.start()
        let proxy = try #require(await connect.proxyURL)
        let root = URL.temporaryDirectory.appending(component: "IskraBlindTests-\(UUID())")
        return Rig(homeserver: homeserver,
                   address: "https://127.0.0.1:\(port)",
                   connect: connect,
                   route: .init(proxy: proxy, rootCertificates: [tls.certificate], heard: heard),
                   environment: AppEnvironment(storage: .scratch(root)),
                   sessionStore: SessionStore(secrets: InMemorySecrets()))
    }

    /// A bridge that will not go to the server is said to be that, not "server not found" — which
    /// is what the SDK makes of a connection the bridge reset, and which would send the person back
    /// to the address field to hunt for a typo that is not there.
    @Test("sign-in through a bridge that refuses the server names the refusal")
    func signInThroughARefusingBridge() async throws {
        let tunnel = await TestStreamTunnel()
        await tunnel.bridge.refusing(with: StreamReason.notAllowed)
        let rig = try await rig(upstream: tunnel, heard: tunnel.heard)
        defer { Task { await rig.stop() } }

        do {
            _ = try await rig.authentication().startSignIn(homeserverAddress: rig.address)
            Issue.record("sign-in went through a bridge that refuses everything")
        } catch AuthenticationError.bridgeRefused(let refusal) {
            #expect(refusal == .notAllowed)
        } catch {
            Issue.record("expected the bridge's refusal, got \(error)")
        }
    }

    @Test("sign-in, sliding sync, media and the push client all go through the proxy")
    func everythingGoesThroughTheProxy() async throws {
        let pipe = DirectPipe()
        let rig = try await rig(upstream: pipe)
        defer { Task { await rig.stop() } }

        // Sign-in: discovery, the login flows, the password.
        let authentication = rig.authentication()
        _ = try await authentication.startSignIn(homeserverAddress: rig.address)
        let session = try await authentication.signIn(username: "sasha", password: "demo")
        try await session.start()

        // Sliding sync.
        let synced = await eventually { session.roomList.rooms.count >= 8 }
        #expect(synced, "rooms: \(session.roomList.rooms.count)")

        // Media: a photo out of the timeline, downloaded.
        let room = try #require(session.roomList.room(withID: "!anya:iskra.demo"))
        let timeline = TimelineStore(room: room, ownUserID: "@sasha:iskra.demo")
        try await timeline.start()
        let messages = { timeline.rows.compactMap { row -> Message? in
            if case let .message(message) = row { return message }
            return nil
        } }
        let loaded = await eventually { messages().contains { if case .image = $0.kind { true } else { false } } }
        #expect(loaded)
        let photo = try #require(messages().lazy.compactMap { message -> IskraCore.Attachment? in
            if case let .image(attachment) = message.kind { return attachment }
            return nil
        }.first)
        let bytes = try await session.media().data(for: photo)
        #expect(!bytes.isEmpty)

        // The notification extension's client: built by a second `AuthenticationService` from what
        // sign-in wrote down, exactly as `PushDecoder` builds it, and asked for one event. With the
        // app's session closed first — in life they are two processes, and here one process would
        // be opening one store twice.
        let eventID = try #require(messages().last { $0.id.hasPrefix("$") }?.id)
        timeline.stop()
        await session.close()
        let pushClient = try #require(try await rig.authentication()
            .restoreClient(sessionID: session.sessionID, forPushIn: "!anya:iskra.demo"))
        let notifications = try await pushClient.notificationClient(processSetup: .multipleProcesses)
        _ = try await notifications.getNotification(roomId: "!anya:iskra.demo", eventId: eventID)

        // What the homeserver saw, and where it came from.
        let seen = await rig.homeserver.requestLog.map(\.target)
        #expect(seen.contains { $0.contains("/login") })
        #expect(seen.contains { $0.contains("simplified_msc3575/sync") || $0.contains("/v5/sync") })
        #expect(seen.contains { $0.contains("/media/") })

        let arrived = Set(await rig.homeserver.peerPorts)
        let piped = Set(pipe.ports)
        #expect(!arrived.isEmpty)
        #expect(arrived.isSubset(of: piped), "connections that went around the proxy: \(arrived.subtracting(piped))")
        #expect(await rig.connect.refused == 0)
    }

    /// The same SDK, through protocol v2 itself: every connection a stream of frames, through a
    /// stand-in bridge whose relays reorder and duplicate. TLS rides on top untouched — the
    /// certificate is checked by the SDK, at the homeserver's end of the stream.
    @Test("the SDK signs in and syncs through streams that are reordered and duplicated")
    func throughStreams() async throws {
        let tunnel = await TestStreamTunnel()
        let rig = try await rig(upstream: tunnel)
        defer { Task { await rig.stop() } }

        let authentication = rig.authentication()
        _ = try await authentication.startSignIn(homeserverAddress: rig.address)
        let session = try await authentication.signIn(username: "sasha", password: "demo")
        try await session.start()
        let synced = await eventually { session.roomList.rooms.count >= 8 }
        #expect(synced, "rooms: \(session.roomList.rooms.count)")
        await session.close()

        #expect(await tunnel.bridge.opened > 0)
        #expect(!tunnel.ended.contains { if case let .reset(reason) = $0 { reason != StreamReason.closed } else { false } },
                "\(tunnel.ended)")
    }

    private func eventually(seconds: Double = 20, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return condition()
    }
}

/// The bridge check, on the path the SDK takes: a `URLSession` through the `CONNECT` listener, with
/// the listener's secret, and TLS to the homeserver end to end.
@Suite("Bridge check")
struct BridgeCheckTests {
    /// Trusts the tests' own certificate and nothing else — the one thing `URLSession` cannot be
    /// told through the proxy.
    final class TrustTheTestServer: NSObject, URLSessionDelegate, Sendable {
        let certificate: Data

        init(_ certificate: Data) { self.certificate = certificate }

        func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge)
            async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
            guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
                  let trust = challenge.protectionSpace.serverTrust,
                  let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first,
                  SecCertificateCopyData(leaf) as Data == certificate
            else { return (.performDefaultHandling, nil) }
            return (.useCredential, URLCredential(trust: trust))
        }
    }

    @Test("a homeserver behind the listener is reachable")
    func reachable() async throws {
        let tls = try TestTLS.make()
        let homeserver = LocalHTTPProxy(upstream: MockHomeserver(), tls: tls.identity)
        let port = try await homeserver.start()
        defer { Task { await homeserver.stop() } }
        let connect = LocalConnectProxy(upstream: NamedPipe())
        try await connect.start()
        defer { Task { await connect.stop() } }

        let address = "https://\(NamedPipe.name):\(port)"
        let outcome = await BridgeCheck.check(through: connect,
                                              homeserver: try #require(URL(string: address)),
                                              limit: .seconds(10),
                                              delegate: TrustTheTestServer(tls.certificate))
        guard case .reachable = outcome else {
            Issue.record("expected reachable, got \(outcome)")
            return
        }
        // Through the listener, not around it — and with its secret: URLSession asks without it
        // first, takes the `407`, and asks again with it. A session that never learnt the secret
        // would have been refused every time and never reached the homeserver.
        #expect(await connect.carried >= 1)
    }

    /// The bridge's word for a refusal, not a timeout: "the bridge will not take you there" is a
    /// different problem from a bridge that is not running.
    @Test("a bridge that will not take you there says so")
    func refused() async throws {
        let tunnel = await TestStreamTunnel()
        await tunnel.bridge.refusing(with: StreamReason.notMatrix)
        let connect = LocalConnectProxy(upstream: tunnel)
        try await connect.start()
        defer { Task { await connect.stop() } }

        let outcome = await BridgeCheck.check(through: connect,
                                              homeserver: try #require(URL(string: "https://example.org")),
                                              limit: .seconds(10), heard: tunnel.heard)
        #expect(outcome == .refused(.notMatrix))
        // URLSession may try a reset connection again; every try is refused the same way.
        #expect(!tunnel.ended.isEmpty)
        #expect(tunnel.ended.allSatisfy { $0 == .reset(StreamReason.notMatrix) }, "\(tunnel.ended)")
    }
}
