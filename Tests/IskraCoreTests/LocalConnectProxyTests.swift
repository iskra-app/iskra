import Foundation
import Testing
@testable import IskraCore

/// The blind bridge's local end: who gets through the `CONNECT` listener, and what a stream does to
/// the bytes on the way — in order, whole, however the relays shuffle the frames.
@Suite("CONNECT proxy and streams", .serialized)
struct LocalConnectProxyTests {
    // MARK: - Who gets through

    @Test("a CONNECT without the secret is answered 407")
    func noSecretNoEntry() async throws {
        let proxy = LocalConnectProxy(upstream: DirectPipe())
        let port = try await proxy.start()
        defer { Task { await proxy.stop() } }

        let socket = try await ConnectClient.connect(port: port)
        let bare = "CONNECT matrix.org:443 HTTP/1.1\r\nHost: matrix.org:443\r\n\r\n"
        #expect(try await ConnectClient.statusLine(after: bare, on: socket).hasPrefix("HTTP/1.1 407"))

        let wrong = try await ConnectClient.connect(port: port)
        let guessed = ConnectClient.head(to: "matrix.org:443", proxyURL: "http://iskra:guess@127.0.0.1:1")
        #expect(try await ConnectClient.statusLine(after: guessed, on: wrong).hasPrefix("HTTP/1.1 407"))
        #expect(await proxy.refused == 2)
        #expect(await proxy.carried == 0)
    }

    /// Only `CONNECT`. A plain `GET http://…` is what reqwest would send for an `http` homeserver,
    /// and carrying it would put a request in front of the bridge in the clear.
    @Test("anything but CONNECT is answered 405")
    func onlyConnect() async throws {
        let proxy = LocalConnectProxy(upstream: DirectPipe())
        let port = try await proxy.start()
        defer { Task { await proxy.stop() } }

        let socket = try await ConnectClient.connect(port: port)
        let get = "GET http://matrix.org/_matrix/client/versions HTTP/1.1\r\nHost: matrix.org\r\n\r\n"
        #expect(try await ConnectClient.statusLine(after: get, on: socket).hasPrefix("HTTP/1.1 405"))
    }

    @Test func authoritiesSplitIncludingIPv6() {
        #expect(LocalConnectProxy.splitAuthority("matrix.org:443")! == ("matrix.org", 443))
        #expect(LocalConnectProxy.splitAuthority("[::1]:8448")! == ("::1", 8448))
        #expect(LocalConnectProxy.splitAuthority("matrix.org") == nil)
        #expect(LocalConnectProxy.splitAuthority(":443") == nil)
        #expect(LocalConnectProxy.splitAuthority("matrix.org:0") == nil)
    }

    @Test("with the secret, the connection is carried, and what came with the head goes first")
    func carried() async throws {
        let echo = EchoServer()
        let target = try await echo.start()
        defer { Task { await echo.stop() } }
        let proxy = LocalConnectProxy(upstream: DirectPipe())
        let port = try await proxy.start()
        defer { Task { await proxy.stop() } }

        let socket = try await ConnectClient.connect(port: port)
        // The bytes after the head ride in the same write, the way a client in a hurry sends them.
        let head = ConnectClient.head(to: "127.0.0.1:\(target)", proxyURL: await proxy.proxyURL)
        try await socket.send(Data((head + "early").utf8))
        var answer = Data()
        let blank = Data("\r\n\r\n".utf8)
        while answer.range(of: blank).map({ answer.count - $0.upperBound < 5 }) ?? true,
              let chunk = try await socket.receive() {
            answer.append(chunk)
        }
        #expect(String(decoding: answer, as: UTF8.self).hasPrefix("HTTP/1.1 200"))
        let echoed = answer.range(of: blank).map { Data(answer[$0.upperBound...]) }
        #expect(echoed == Data("early".utf8))
        socket.close()
    }

    /// TN2277, the same as `LocalHTTPProxy`'s — the shared listener is what is being tested.
    @Test("a reclaimed listener comes back on the same port")
    func reclaimed() async throws {
        let echo = EchoServer()
        let target = try await echo.start()
        defer { Task { await echo.stop() } }
        let proxy = LocalConnectProxy(upstream: DirectPipe())
        let port = try await proxy.start()
        defer { Task { await proxy.stop() } }

        await proxy.simulateReclaim()
        await proxy.ensureListening()
        #expect(await proxy.port == port)

        // The listener's own state handler raises it again; the cancellation it answers is
        // reported a moment after it happens, so the whole exchange is tried until it succeeds —
        // a connection can be accepted by the listener on its way out and dropped with it.
        let head = ConnectClient.head(to: "127.0.0.1:\(target)", proxyURL: await proxy.proxyURL)
        var status = ""
        for _ in 0..<40 where !status.hasPrefix("HTTP/1.1 200") {
            if let socket = try? await ConnectClient.connect(port: port),
               let line = try? await ConnectClient.statusLine(after: head, on: socket) {
                status = line
                socket.close()
            } else {
                try await Task.sleep(for: .milliseconds(50))
            }
        }
        #expect(status.hasPrefix("HTTP/1.1 200"))
    }

    // MARK: - Streams

    /// Three megabytes through protocol v2 and back, through a bridge whose relays reorder and
    /// duplicate: every byte, in order. Three megabytes is three windows each way, so the
    /// acknowledgements have to work for it to finish at all.
    @Test("a stream carries every byte in order, through reordering and duplicates")
    func streamCarriesEverything() async throws {
        let echo = EchoServer()
        let target = try await echo.start()
        defer { Task { await echo.stop() } }
        let tunnel = await TestStreamTunnel()
        let proxy = LocalConnectProxy(upstream: tunnel)
        let port = try await proxy.start()
        defer { Task { await proxy.stop() } }

        let socket = try await ConnectClient.connect(port: port)
        let status = try await ConnectClient.statusLine(
            after: ConnectClient.head(to: "127.0.0.1:\(target)", proxyURL: await proxy.proxyURL), on: socket)
        #expect(status.hasPrefix("HTTP/1.1 200"))

        let payload = Data((0..<(3 * 1024 * 1024)).map { _ in UInt8.random(in: .min ... .max) })
        let sending = Task {
            var offset = 0
            while offset < payload.count {
                let end = min(offset + 100_000, payload.count)
                try await socket.send(payload[offset..<end])
                offset = end
            }
            await socket.finishWriting()
        }
        let received = try await withTimeout(.seconds(60)) {
            try await ConnectClient.read(Int.max, from: socket)
        }
        try await sending.value
        #expect(received.count == payload.count)
        #expect(received == payload)
        #expect(await tunnel.bridge.opened == 1)

        // Both halves closed in order: an ordinary end, not a reset.
        let closed = await eventuallyTrue { tunnel.ended == [.closed] }
        #expect(closed, "\(tunnel.ended)")
    }

    /// A segment no relay delivered never comes. After the gap timeout the stream is reset, and the
    /// client sees its connection broken — which is what makes reqwest retry on a fresh one.
    @Test("a hole that does not fill resets the stream")
    func aHoleResets() async throws {
        let echo = EchoServer()
        let target = try await echo.start()
        defer { Task { await echo.stop() } }
        let tunnel = await TestStreamTunnel()
        await tunnel.bridge.dropping { $0.op == .data && $0.seq == 1 }
        let proxy = LocalConnectProxy(upstream: tunnel)
        let port = try await proxy.start()
        defer { Task { await proxy.stop() } }

        let socket = try await ConnectClient.connect(port: port)
        _ = try await ConnectClient.statusLine(
            after: ConnectClient.head(to: "127.0.0.1:\(target)", proxyURL: await proxy.proxyURL), on: socket)
        // Three writes with pauses between them: three segments, the middle one lost.
        for word in ["one", "two", "three"] {
            try await socket.send(Data(word.utf8))
            try await Task.sleep(for: .milliseconds(50))
        }
        let reset = await eventuallyTrue(seconds: 10) { tunnel.ended.contains(.reset(StreamReason.gap)) }
        #expect(reset, "\(tunnel.ended)")
    }

    /// A bridge that cannot reach the host says so, and the stream ends with its word for it.
    @Test("a host the bridge cannot reach resets the stream with its reason")
    func unreachable() async throws {
        let tunnel = await TestStreamTunnel()
        let proxy = LocalConnectProxy(upstream: tunnel)
        let port = try await proxy.start()
        defer { Task { await proxy.stop() } }

        // A port nothing listens on: bound and released at once.
        let nothing = EchoServer()
        let closed = try await nothing.start()
        await nothing.stop()

        let socket = try await ConnectClient.connect(port: port)
        _ = try await ConnectClient.statusLine(
            after: ConnectClient.head(to: "127.0.0.1:\(closed)", proxyURL: await proxy.proxyURL), on: socket)
        try await socket.send(Data("hello".utf8))
        let reset = await eventuallyTrue { tunnel.ended == [.reset(StreamReason.unreachable)] }
        #expect(reset, "\(tunnel.ended)")
    }
}

/// Poll until true, or give up. Never a fixed sleep: what is waited on here is a network.
func eventuallyTrue(seconds: Double = 5, _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .milliseconds(Int(seconds * 1000))
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return await condition()
}
