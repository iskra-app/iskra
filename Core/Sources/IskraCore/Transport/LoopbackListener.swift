import Foundation
import Network

/// A TCP listener on `127.0.0.1` that comes back by itself when iOS takes it away.
///
/// Both of the app's loopback listeners stand on this — `LocalHTTPProxy`, which the SDK is pointed
/// at as its homeserver, and `LocalConnectProxy`, which it is pointed at as its proxy — because
/// both are lost the same way: **iOS takes listening sockets away from a suspended app** (TN2277,
/// "socket resource reclaim"). The app comes back from the background, the listener it raised at
/// launch is gone, and the SDK — which knows the address only as `127.0.0.1:<that port>` — gets its
/// connections refused and reports that there is no network. Which is what it did, on a phone,
/// every time the app had been in a pocket long enough, while the bridge on the far side answered
/// perfectly well. One copy of the cure, so that the two cannot drift apart.
///
/// Bound to loopback explicitly. A listener on `0.0.0.0` would be an open door to somebody's
/// session, reachable by anything on the same Wi-Fi.
actor LoopbackListener {
    private let tls: TLSIdentity?
    private let onConnection: @Sendable (NWConnection) -> Void
    private var listener: NWListener?
    private(set) var port: UInt16?
    /// Set by `stop()`, and only by it: a listener that ends while this is false was taken away, and
    /// is raised again. See `ensureListening`.
    private var stopped = false

    /// - Parameter tls: an identity to speak TLS with. Only the tests have one: they stand a
    ///   homeserver behind real TLS, so that a client built with a proxy has something to `CONNECT`
    ///   to the way it would to matrix.org.
    init(tls: TLSIdentity? = nil, onConnection: @escaping @Sendable (NWConnection) -> Void) {
        self.tls = tls
        self.onConnection = onConnection
    }

    /// Bind, and return the port the system chose.
    ///
    /// The port is asked for rather than picked: a hard-coded one is taken sooner or later, and on
    /// a phone the failure would look like the tunnel being broken.
    func start() async throws -> UInt16 {
        stopped = false
        let port = try await bind(port: .any)
        self.port = port
        return port
    }

    func stop() {
        stopped = true
        let listener = self.listener
        self.listener = nil
        listener?.cancel()
        port = nil
    }

    /// Make sure the listener is still there, and raise it again on the same port if it is not.
    ///
    /// The listener's own state handler notices a reclaim when the app wakes and rebinds on its
    /// own; this is the same thing asked for deliberately, from `UserSession.enteredForeground`,
    /// *before* sync starts again — so that the first request after a wake is not the one that
    /// finds the port closed.
    func ensureListening() async {
        guard !stopped, port != nil else { return }
        if let listener, listener.state == .ready { return }
        await relisten()
    }

    /// What a reclaim looks like from the inside: the socket goes without anybody calling `stop()`.
    /// For tests, which cannot suspend a process to make iOS do it.
    func simulateReclaim() {
        listener?.cancel()
    }

    private func bind(port requested: NWEndpoint.Port) async throws -> UInt16 {
        let parameters: NWParameters
        if let tls {
            let options = NWProtocolTLS.Options()
            sec_protocol_options_set_local_identity(options.securityProtocolOptions, tls.identity)
            parameters = NWParameters(tls: options, tcp: NWProtocolTCP.Options())
        } else {
            parameters = .tcp
        }
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: requested)
        parameters.allowLocalEndpointReuse = true

        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = onConnection

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let resumed = ResumeOnce(continuation)
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready: resumed.succeed()
                // After `.ready` there is nobody waiting on the continuation, and a failure is not
                // a failure to start — it is the listener being lost, which used to be ignored
                // here. That silence was the whole of the "no network after the background" bug.
                case .failed(let error):
                    if !resumed.fail(error) { Task { await self?.lost(listener) } }
                case .cancelled:
                    if !resumed.fail(LocalHTTPProxy.ProxyError.notStarted) { Task { await self?.lost(listener) } }
                default: break
                }
            }
            listener.start(queue: .global(qos: .userInitiated))
        }

        guard let port = listener.port?.rawValue else { throw LocalHTTPProxy.ProxyError.notStarted }
        return port
    }

    /// A listener went away without `stop()` being called.
    private func lost(_ listener: NWListener) async {
        // Only the current one matters: a listener already replaced, or one cancelled by `stop()`,
        // reports its own end too, and must not start a second rebind.
        guard !stopped, listener === self.listener else { return }
        Log.session.warning("the local listener was lost; raising it again on the same port")
        await relisten()
    }

    /// Bind again on the port the SDK already knows. A new port would be no use: the client was
    /// built with the old one and cannot be told another.
    private func relisten() async {
        guard !stopped, let port, let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        let previous = listener
        listener = nil
        previous?.cancel()

        // A few tries, because the port can take a moment to be free again after a reclaim.
        for attempt in 1...5 {
            guard !stopped else { return }
            do {
                _ = try await bind(port: nwPort)
                return
            } catch {
                Log.session.warning("the listener would not come back (try \(attempt)): \(Log.describe(error), privacy: .public)")
                try? await Task.sleep(for: .milliseconds(200 * attempt))
            }
        }
    }
}

/// A TLS identity, carried into the listener's actor. `sec_identity_t` predates strict concurrency;
/// it is an immutable reference and safe to share.
struct TLSIdentity: @unchecked Sendable {
    let identity: sec_identity_t
}

// MARK: - Continuation guards
//
// Network.framework handlers can fire more than once (a state handler certainly does), and
// resuming a continuation twice is a crash, not a warning. These make "first one wins" explicit.

final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    func succeed(_ value: T) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }

    /// Whether this was the call that resumed — `false` when somebody already had, which is how a
    /// state handler tells "failed to start" from "failed later".
    @discardableResult
    func fail(_ error: Error) -> Bool {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(throwing: error)
        return pending != nil
    }
}

extension ResumeOnce where T == Void {
    func succeed() { succeed(()) }
}

final class ResumeOnceValue<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?

    init(_ continuation: CheckedContinuation<T, Never>) {
        self.continuation = continuation
    }

    func finish(_ value: T) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}

extension ResumeOnceValue where T == Void {
    func finish() { finish(()) }
}
