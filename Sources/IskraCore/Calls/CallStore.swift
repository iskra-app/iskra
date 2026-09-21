import Foundation
import Observation
import MatrixRustSDK

/// Whether the caller wants to be seen, and whether the call already exists.
///
/// Our own vocabulary rather than the SDK's `Intent`, which has six cases because it folds in
/// whether the room is a direct chat — a fact the store can ask the room itself. What the screen
/// knows is only these two bits.
public enum CallIntent: Sendable, Equatable {
    /// Nobody is calling yet. The room is about to hear a ring.
    case start(video: Bool)
    /// There is a call in this room already; join it.
    case join(video: Bool)

    var wantsVideo: Bool {
        switch self {
        case let .start(video), let .join(video): video
        }
    }
}

/// Light or dark, for the page. Spelled out because `IskraCore` cannot see a `ColorScheme`.
public enum CallTheme: String, Sendable {
    case light
    case dark
}

/// Why a call could not be placed, in terms a screen can turn into a sentence.
public enum CallFailure: Sendable, Equatable {
    /// The server names no Element Call, or does not carry MatrixRTC. See `ElementCallDiscovery`.
    case unavailable
    /// The room, the widget or the URL would not be built. The SDK's own words are logged, not
    /// shown: they are Rust error strings and mean nothing to the person holding the phone.
    case couldNotStart
}

/// One call, from the moment the button is pressed until the screen closes.
///
/// ## What this is and is not
///
/// It is **not** an implementation of a call. Not one line of WebRTC, signalling or media is
/// written here or anywhere else in this app, and that is deliberate — `CLAUDE.md` says all
/// cryptography belongs to the Rust SDK and none of it is reimplemented, and a call's encryption
/// is cryptography. What happens instead is what Element's own clients do: the SDK builds a
/// *widget*, which is the Element Call application, and a *driver*, which is the SDK's end of a
/// conversation with that application. This store owns both. The application itself is drawn by a
/// web view in `IskraFeatures`, which is the only place it can be, because `IskraCore` has no UI.
///
/// ## The seam, and why it is a string
///
/// The driver and the page talk in JSON. That is the whole protocol, and a JSON string is a value
/// type, so it can cross from here to a view without carrying an SDK type with it — which is what
/// lets this file keep the rule that `IskraCore` never leaks the SDK upward. The view gets `url`
/// and `outgoing`, and hands back `incoming(_:)`. It never sees a `WidgetDriver`.
///
/// ## What the page is allowed to do
///
/// `acquireCapabilities` is asked what the widget may read and send, and it answers with
/// `getElementCallRequiredPermissions` — the set Element Call actually needs — rather than with
/// whatever the page asked for. The distinction is the point: the argument to that method is a
/// *request* from a remote web application, and granting a request because it was made is how a
/// page ends up reading a room it had no business reading.
@MainActor
@Observable
public final class CallStore {
    /// Where the call has got to.
    public enum State: Sendable, Equatable {
        /// Nothing has been asked for yet.
        case idle
        /// The widget is being built and the URL generated.
        case preparing
        /// Ready to be drawn. The view loads this address.
        case ready(URL)
        case failed(CallFailure)
    }

    public private(set) var state: State = .idle

    /// Messages from the SDK to the page. The view forwards each one into the web view.
    ///
    /// A stream rather than a callback because the view is the consumer and a view is the wrong
    /// thing to hold a reference to from here — it comes and goes, and `for await` in a `.task`
    /// ends by itself when it does.
    public let outgoing: AsyncStream<String>

    private let room: Room
    private let ownUserID: String
    private let deviceID: String
    private let widgetBase: URL
    private let continuation: AsyncStream<String>.Continuation

    /// Held because letting go of either one ends the call. The driver runs for as long as the
    /// call does; the handle is the pipe.
    private var driver: WidgetDriver?
    private var handle: WidgetDriverHandle?
    private var running: Task<Void, Never>?
    private var pump: Task<Void, Never>?

    /// A widget needs an ID, and it has to be the same one in the URL and in the driver.
    ///
    /// Made once per store, not per call, so that a retry inside the same screen does not look to
    /// Element Call like a second widget appearing beside the first.
    private let widgetID = UUID().uuidString

    init(room: Room, ownUserID: String, deviceID: String, widgetBase: URL) {
        self.room = room
        self.ownUserID = ownUserID
        self.deviceID = deviceID
        self.widgetBase = widgetBase

        var escapee: AsyncStream<String>.Continuation!
        self.outgoing = AsyncStream { escapee = $0 }
        self.continuation = escapee
    }

    deinit {
        continuation.finish()
    }

    /// Builds the widget and generates the address to load. Idempotent: asking twice while a call
    /// is already up does nothing, which matters because a view's `.task` can run more than once.
    public func start(intent: CallIntent, theme: CallTheme, language: String) async {
        guard case .idle = state else { return }
        state = .preparing

        // Asked over the network rather than read from the cache. `encryptionState()` answers
        // `.unknown` on a cold start, and treating unknown as "not encrypted" would place an
        // unencrypted call in an encrypted room — which nobody in the room would notice.
        let encryption: EncryptionSystem
        do {
            encryption = try await room.latestEncryptionState() == .encrypted
                ? .perParticipantKeys
                : .unencrypted
        } catch {
            Log.calls.error("could not settle the room's encryption: \(Log.describe(error), privacy: .public)")
            state = .failed(.couldNotStart)
            return
        }

        let isDirect = await room.isDirect()

        do {
            let settings = try newVirtualElementCallWidget(
                props: VirtualElementCallWidgetProperties(
                    elementCallUrl: widgetBase.absoluteString,
                    widgetId: widgetID,
                    // The page is loaded straight into a web view, so there is no containing page
                    // to name. It is given its own address, which is the closest true answer and
                    // what the widget's postMessage checks compare against.
                    parentUrl: widgetBase.absoluteString,
                    encryption: encryption
                ),
                config: VirtualElementCallWidgetConfig(
                    intent: Self.sdkIntent(for: intent, isDirect: isDirect),
                    // The lobby is a second confirmation screen, and the person has already
                    // pressed "call". Joining an existing call keeps it: walking into a room
                    // where people are already talking is a moment to check the microphone.
                    skipLobby: {
                        if case .start = intent { return true } else { return false }
                    }(),
                    // Our own bar is drawn above the web view. Two headers is one too many, and
                    // the one that should go is the one that cannot say "back".
                    hideHeader: true
                )
            )

            let pair = try makeWidgetDriver(settings: settings)
            driver = pair.driver
            handle = pair.handle

            let provider = ElementCallCapabilities(ownUserID: ownUserID, deviceID: deviceID)
            running = Task { [driver = pair.driver, room] in
                await driver.run(room: room, capabilitiesProvider: provider)
            }

            pump = Task { [handle = pair.handle, continuation] in
                // `recv` answers nil exactly once, when the driver is done. That is also the only
                // way out of this loop, so ending the call ends the task.
                while let message = await handle.recv() {
                    continuation.yield(message)
                }
            }

            let address = try await generateWebviewUrl(
                widgetSettings: settings,
                room: room,
                props: ClientProperties(clientId: "moscow.swag.iskra",
                                        languageTag: language,
                                        theme: theme.rawValue)
            )

            guard let url = URL(string: address) else {
                state = .failed(.couldNotStart)
                return
            }
            state = .ready(url)
        } catch {
            Log.calls.error("the widget would not be built: \(Log.describe(error), privacy: .public)")
            stop()
            state = .failed(.couldNotStart)
        }
    }

    /// A message the page sent, on its way to the SDK.
    public func incoming(_ json: String) {
        guard let handle else { return }
        Task { _ = await handle.send(msg: json) }
    }

    /// Ends the call and lets go of everything holding it open.
    ///
    /// Called when the screen closes, and by `UserSession` when the session goes away — a driver
    /// still running over a store that has been deleted is the same hazard as a live timeline
    /// listener, and it is torn down the same way.
    public func stop() {
        pump?.cancel()
        running?.cancel()
        pump = nil
        running = nil
        handle = nil
        driver = nil
        state = .idle
    }

    /// Six SDK cases from two of ours, plus the one fact the room knows about itself.
    ///
    /// Voice-only is a real intent rather than "video with the camera off": the other side is told
    /// which kind of call this is, and a voice call that announces itself as video is a call
    /// somebody answers expecting to be seen.
    private static func sdkIntent(for intent: CallIntent, isDirect: Bool) -> Intent {
        switch (intent, isDirect) {
        case (.start(video: true), true): .startCallDm
        case (.start(video: false), true): .startCallDmVoice
        case (.join(video: true), true): .joinExistingDm
        case (.join(video: false), true): .joinExistingDmVoice
        // A group has no voice-only intent in the SDK's vocabulary, and inventing one on top would
        // mean saying something the other clients do not understand.
        case (.start, false): .startCall
        case (.join, false): .joinExisting
        }
    }
}

/// What the widget is allowed to do, decided here and not by the widget.
///
/// See the note on `CallStore`: the capabilities handed in are what the page *asked* for, and the
/// answer ignores them in favour of what Element Call is known to need.
private final class ElementCallCapabilities: WidgetCapabilitiesProvider {
    private let required: WidgetCapabilities

    init(ownUserID: String, deviceID: String) {
        required = getElementCallRequiredPermissions(ownUserId: ownUserID, ownDeviceId: deviceID)
    }

    func acquireCapabilities(capabilities: WidgetCapabilities) -> WidgetCapabilities {
        required
    }
}
