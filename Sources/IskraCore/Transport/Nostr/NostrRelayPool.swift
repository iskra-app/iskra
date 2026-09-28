import Foundation
import OSLog

/// What to ask relays for. A nostr filter, narrowed to the two fields this app needs.
struct NostrFilter: Sendable {
    var kinds: [Int]
    var authors: [String]
    /// The `#p` tag — "addressed to this key".
    var recipients: [String]
    var since: Int

    var json: [String: Any] {
        ["kinds": kinds, "authors": authors, "#p": recipients, "since": since]
    }
}

/// Several relays, treated as one.
///
/// A list of relays is not a spare tyre, it is how the thing works: an event is published to all
/// of them at once and the answer comes back from whichever is quickest, so one relay being down —
/// which is an ordinary Tuesday, not an outage — costs nothing. The other side of that is
/// duplicates, since every relay delivers its own copy of the same event; they are dropped here by
/// id, so nothing above this ever sees them.
///
/// One socket per relay and one reader per socket, for the life of the pool. Not one per request:
/// the Rust client learned that the hard way, where a subscription per request left the Nth call
/// with N live subscriptions on every relay, each delivering its own copy of every answer.
actor NostrRelayPool {
    private let relays: [URL]
    private let filter: NostrFilter
    private let subscriptionID = "iskra-" + UUID().uuidString.prefix(8)
    private let onEvent: @Sendable (NostrEvent) -> Void
    private let log = Logger(subsystem: "moscow.swag.iskra", category: "tunnel")

    private let session: URLSession
    /// The open sockets, by relay. A relay that is reconnecting is simply absent.
    private var sockets: [URL: WebSocket] = [:]
    private var readers: [Task<Void, Never>] = []
    private var running = false

    /// Event ids already handed upward, newest last, so a duplicate from a second relay is
    /// recognised. Bounded: this runs for the life of a session and an unbounded set would be a
    /// slow leak with no symptom but memory.
    private var seen: [String] = []
    private var seenSet: Set<String> = []

    init(relays: [URL], filter: NostrFilter, onEvent: @escaping @Sendable (NostrEvent) -> Void) {
        self.relays = relays
        self.filter = filter
        self.onEvent = onEvent

        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = true
        self.session = URLSession(configuration: configuration)
    }

    /// Relays with a socket open right now.
    var connected: [URL] { Array(sockets.keys) }

    func start() {
        guard !running else { return }
        running = true
        for relay in relays {
            readers.append(Task { [weak self] in await self?.run(relay) })
        }
    }

    func stop() {
        running = false
        for reader in readers { reader.cancel() }
        readers.removeAll()
        for (_, socket) in sockets { socket.cancel() }
        sockets.removeAll()
    }

    /// Publish to every relay that is up.
    ///
    /// Sent to all of them rather than to one: a relay can accept a connection and then quietly
    /// drop what it is given, and there is no way to tell from here. Whoever carries it first wins.
    ///
    /// `waitingUpTo` covers the cold start. The first request usually arrives while the websockets
    /// are still shaking hands, and failing it for that would make the tunnel look broken every
    /// time the app was opened — a few seconds of waiting is the difference between "no relay is
    /// answering" meaning something and meaning nothing.
    func publish(_ event: NostrEvent, waitingUpTo limit: Duration = .seconds(10)) async throws {
        if sockets.isEmpty {
            let deadline = ContinuousClock.now.advanced(by: limit)
            while sockets.isEmpty, running, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        guard !sockets.isEmpty else { throw NostrRelayError.noRelayConnected }
        guard let message = Self.encode(["EVENT", event.json]) else {
            throw NostrRelayError.cannotEncode
        }
        for (relay, socket) in sockets {
            socket.send(message) { [weak self] error in
                guard let error else { return }
                Task { await self?.socketFailed(relay, error: error) }
            }
        }
    }

    // MARK: - One relay

    private func run(_ relay: URL) async {
        var backoff = Duration.seconds(1)
        while running, !Task.isCancelled {
            let socket = WebSocket(session.webSocketTask(with: relay))
            socket.resume()
            sockets[relay] = socket

            if let request = Self.encode(["REQ", subscriptionID, filter.json]) {
                socket.send(request) { _ in }
            }

            do {
                while running, !Task.isCancelled {
                    let message = try await socket.receive()
                    backoff = .seconds(1)
                    handle(message, from: relay)
                }
            } catch {
                // Ordinary. Relays go away, Wi-Fi changes, a phone comes out of a pocket.
                log.debug("relay dropped: \(relay.absoluteString, privacy: .public)")
            }

            sockets[relay] = nil
            socket.cancel()
            guard running, !Task.isCancelled else { return }
            try? await Task.sleep(for: backoff)
            backoff = min(backoff * 2, .seconds(30))
        }
    }

    private func socketFailed(_ relay: URL, error: any Error) {
        sockets[relay] = nil
    }

    /// One frame from a relay.
    ///
    /// Relay messages are JSON arrays whose first element names them: `EVENT`, `OK`, `EOSE`,
    /// `NOTICE`, `CLOSED`. Only `EVENT` carries anything; the rest are noted and dropped, because
    /// the tunnel's own answer is the only confirmation that means anything.
    private func handle(_ message: String, from relay: URL) {
        guard let data = message.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [Any],
              let type = array.first as? String
        else { return }

        switch type {
        case "EVENT":
            guard array.count >= 3, let event = NostrEvent(json: array[2]) else { return }
            guard !seenSet.contains(event.id) else { return }
            remember(event.id)
            guard event.isAuthentic() else {
                log.warning("relay served an event that does not verify")
                return
            }
            onEvent(event)
        case "NOTICE", "CLOSED":
            // A relay saying no — usually rate limiting. Worth seeing in a log, and never worth
            // the message itself, which is a remote string.
            log.info("relay \(relay.absoluteString, privacy: .public) said \(type, privacy: .public)")
        default:
            break
        }
    }

    private func remember(_ id: String) {
        seen.append(id)
        seenSet.insert(id)
        if seen.count > 512 {
            let dropped = seen.removeFirst()
            seenSet.remove(dropped)
        }
    }

    private static func encode(_ value: [Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

enum NostrRelayError: Error, Equatable {
    case noRelayConnected
    case cannotEncode
}

/// A websocket, in the one shape this file uses it.
///
/// `URLSessionWebSocketTask` predates strict concurrency and is not `Sendable`, while the reader
/// loop and the publisher necessarily touch the same socket from different tasks. It is safe to:
/// the class is documented as thread-safe, and every method used here is one of the ones that are.
private final class WebSocket: @unchecked Sendable {
    private let task: URLSessionWebSocketTask

    init(_ task: URLSessionWebSocketTask) { self.task = task }

    func resume() { task.resume() }
    func cancel() { task.cancel(with: .goingAway, reason: nil) }

    func send(_ text: String, completion: @escaping @Sendable ((any Error)?) -> Void) {
        task.send(.string(text), completionHandler: completion)
    }

    /// The next text frame. Binary frames are not part of the nostr protocol and are skipped.
    func receive() async throws -> String {
        while true {
            switch try await task.receive() {
            case .string(let text): return text
            case .data: continue
            @unknown default: continue
            }
        }
    }
}
