import Foundation

/// Whether this account can place a call, and where the call would be drawn from.
///
/// Both halves are required and they answer different questions. `serverCarriesCalls` is the
/// homeserver saying it has a MatrixRTC focus to route the media through — without it there is
/// nowhere for the audio to go. `widgetURL` is the address of the Element Call application that
/// draws the call — without it there is nothing to show. A server can have one and not the other.
public struct CallAvailability: Sendable, Equatable {
    /// The Element Call deployment this server points its users at, from `.well-known`.
    public let widgetURL: URL?

    /// The homeserver knows a LiveKit focus: `Client.isLivekitRtcSupported()`, or the
    /// `org.matrix.msc4143.rtc_foci` list in `.well-known` — see `ElementCallDiscovery.Answer`.
    public let serverCarriesCalls: Bool

    public init(widgetURL: URL?, serverCarriesCalls: Bool) {
        self.widgetURL = widgetURL
        self.serverCarriesCalls = serverCarriesCalls
    }

    /// Nothing is offered unless both are true. See the refusal note on `ElementCallDiscovery`.
    public var isAvailable: Bool { widgetURL != nil && serverCarriesCalls }

    /// Nobody can call. Also what every screen holds before the answer has arrived, so that a call
    /// button appears once and never flickers out again.
    public static let none = CallAvailability(widgetURL: nil, serverCarriesCalls: false)
}

/// Where the Element Call application lives, according to the user's own homeserver.
///
/// **There is deliberately no default.** `VirtualElementCallWidgetProperties.elementCallUrl` is a
/// required field, and the obvious way to fill it is `https://call.element.io` — which would make
/// calls work everywhere and would mean that the list of everyone the user talks to is handed to a
/// third party, one room at a time. This project has already refused that trade once: blobatar is
/// a port and not a call to `blobatar.dev`, for exactly this reason, because the seed is a Matrix
/// ID. A call is worse than an avatar: it is who, with whom, and when.
///
/// So the address comes from the server the user chose, and when the server does not name one
/// there is no call button. The same shape as a missing App Group: refused, not worked around.
/// Somebody who runs their own Element Call and whose server does not advertise it can say so by
/// hand — `BetaFeatures.elementCallURLKey` — and that is a sentence they typed, not a default
/// chosen for them.
///
/// ## Which host is asked
///
/// `.well-known` belongs to the *server name* — `matrix.org` — and not to the homeserver base URL
/// it delegates to (`matrix-client.matrix.org`), which commonly serves the API and not this file.
/// So the question goes to `Client.server()`, falling back to the server part of the user's own
/// Matrix ID.
///
/// ## About the bridge
///
/// When the bridge switch is on, the SDK talks to a loopback listener (`LocalHTTPProxy`) whose
/// upstream is the real homeserver, and that listener already carries `/.well-known/matrix/client`
/// — `keepDiscoveryHome` rewrites `m.homeserver.base_url` in the reply and leaves everything else,
/// including `io.element.call`, alone. It cannot be reused here, though: after discovery the
/// listener stands in for the *homeserver*, so a late request through it would ask
/// `matrix-client.matrix.org` for a file only `matrix.org` serves.
///
/// This fetch therefore goes out on its own. Today that is the same route the SDK's own traffic
/// takes, because the bridge in this build is `DirectUpstream` behind the listener and there is no
/// circumvention on the far side yet (see `AuthenticationService.route(to:)`, which says so). **The
/// day a real transport lands on the far side, this is one of the places that has to be pointed at
/// it** — which is why the fetch is a closure and not a hard-wired `URLSession` call.
public struct ElementCallDiscovery: Sendable {
    /// Fetching one URL: the body, and the status the server answered with.
    public typealias Fetch = @Sendable (URL) async throws -> (Data, Int)

    private let fetch: Fetch

    public init(fetch: @escaping Fetch = ElementCallDiscovery.direct) {
        self.fetch = fetch
    }

    /// What a server's `.well-known` says about calls.
    public struct Answer: Sendable, Equatable {
        /// `io.element.call.widget_url`: where the call is drawn from.
        public var widgetURL: URL?

        /// Whether `org.matrix.msc4143.rtc_foci` lists a LiveKit focus: where the media goes.
        ///
        /// Asked here as well as of the SDK, and either answer is enough. From 26.08 the SDK's
        /// `isLivekitRtcSupported()` asks the newer `GET …/msc4143/rtc/transports` endpoint, and a
        /// Synapse that announces its focus the older way — in this very file, which is also where
        /// Element Call itself looks for it — answers that endpoint 404. Trusting the SDK alone took
        /// the call button away from `nope.chat`, a server whose calls work in Element.
        public var hasLiveKitFocus: Bool

        public static let nothing = Answer(widgetURL: nil, hasLiveKitFocus: false)
    }

    /// The Element Call address this server names, or nil where it names none.
    public func widgetURL(forServerName serverName: String) async -> URL? {
        await calls(forServerName: serverName).widgetURL
    }

    /// Everything `.well-known` says about calls — see `Answer`.
    ///
    /// Never throws. Every way this can fail — no such file, a server that is down, JSON that is
    /// not what we expected — means the same thing to the caller, and it is not an error: it is a
    /// server that does not do calls, which is most of them.
    public func calls(forServerName serverName: String) async -> Answer {
        guard let base = TunnelSettings.upstreamURL(from: serverName),
              let target = URL(string: "/.well-known/matrix/client", relativeTo: base)
        else {
            return .nothing
        }

        do {
            // Bounded like every other call the user waits on. A server that accepts a connection
            // and then says nothing must not be able to hold the call button hostage — and the
            // button's absence is a perfectly good answer while we wait.
            let (data, status) = try await withTimeout(.seconds(10)) {
                try await fetch(target)
            }
            guard status == 200 else { return .nothing }
            return Answer(widgetURL: Self.widgetURL(inWellKnown: data),
                          hasLiveKitFocus: Self.hasLiveKitFocus(inWellKnown: data))
        } catch {
            Log.calls.error("could not read .well-known: \(Log.describe(error), privacy: .public)")
            return .nothing
        }
    }

    /// The `io.element.call` section of a `.well-known/matrix/client` document.
    ///
    /// Separated from the fetch so it can be held to real documents in a test without a server —
    /// this is the half that has a shape to get wrong.
    public static func widgetURL(inWellKnown data: Data) -> URL? {
        guard let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let section = document["io.element.call"] as? [String: Any],
              let address = section["widget_url"] as? String
        else {
            return nil
        }

        // `https` or nothing. A `widget_url` on plain http would put the call — and the widget's
        // access to this room — on a connection anybody can rewrite, and a homeserver that names
        // one is a homeserver to disbelieve rather than to humour.
        guard let url = URL(string: address), url.scheme?.lowercased() == "https" else {
            Log.calls.error("the server named a widget_url that is not https, ignoring it")
            return nil
        }

        return url
    }

    /// Whether `org.matrix.msc4143.rtc_foci` names a LiveKit focus with an `https` service URL.
    ///
    /// Only `livekit` counts, because that is the one kind Element Call speaks; the list commonly
    /// carries a placeholder entry copied from Element's own example, and it is ignored, not
    /// rejected. The same `https`-or-nothing rule as the widget: the service hands out the tokens
    /// that let somebody into the call.
    public static func hasLiveKitFocus(inWellKnown data: Data) -> Bool {
        guard let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let foci = document["org.matrix.msc4143.rtc_foci"] as? [[String: Any]]
        else {
            return false
        }
        return foci.contains { focus in
            guard focus["type"] as? String == "livekit",
                  let address = focus["livekit_service_url"] as? String,
                  let url = URL(string: address)
            else {
                return false
            }
            return url.scheme?.lowercased() == "https"
        }
    }

    /// Straight out to the server name over TLS. See the note about the bridge above.
    public static let direct: Fetch = { url in
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (data, status)
    }
}
