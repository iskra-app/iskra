#if os(iOS)
import AVFoundation
import CallKit
import Foundation
import IskraCore

/// The system's own incoming-call screen, and this app's end of it.
///
/// iOS only. There is no CallKit on macOS — see the note on `IncomingCallCenter` for what a Mac
/// does instead.
///
/// ## What is deliberate here
///
/// **`reportIncoming` takes a completion and calls it from CallKit's own.** The caller is a PushKit
/// callback that must not return until the call has been reported, so the ordering is part of the
/// signature rather than something the caller is trusted to remember.
///
/// **The audio session is configured and never activated.** CallKit activates it and says so in
/// `provider(_:didActivate:)`. Doing it here as well is a race for the same resource, and the way
/// it loses is a call whose first seconds are silent. See `AudioSession.callBegan`.
@MainActor
final class CallKitService: NSObject {
    private let provider: CXProvider
    private unowned let center: IncomingCallCenter

    init(center: IncomingCallCenter) {
        self.center = center

        let configuration = CXProviderConfiguration()
        configuration.supportsVideo = true
        // One at a time. Element Call is a room, not a switchboard, and a second incoming call
        // during one is something to decline rather than to juggle.
        configuration.maximumCallsPerCallGroup = 1
        configuration.maximumCallGroups = 1
        // `.generic` because a Matrix room is not a phone number and not an email address. Saying
        // it is either would put a "call back" button in the system's call history that dials
        // something which does not exist.
        configuration.supportedHandleTypes = [.generic]
        if let icon = CallKitService.templateIcon() {
            configuration.iconTemplateImageData = icon
        }

        provider = CXProvider(configuration: configuration)
        super.init()
        provider.setDelegate(self, queue: nil)
    }

    /// Reports a call and calls `then` from inside CallKit's completion.
    ///
    /// Reporting the same UUID twice is a no-op, which is what makes a retried VoIP push harmless
    /// — see `RingID`.
    func reportIncoming(uuid: UUID,
                        title: String,
                        handle: String,
                        isVideo: Bool,
                        then: @escaping @MainActor @Sendable () -> Void) {
        let update = CXCallUpdate()
        update.localizedCallerName = title
        update.remoteHandle = CXHandle(type: .generic, value: handle)
        update.hasVideo = isVideo
        update.supportsHolding = false
        update.supportsGrouping = false
        update.supportsUngrouping = false
        // There is no DTMF in a Matrix call, and offering a keypad on the call screen is offering
        // a control that does nothing.
        update.supportsDTMF = false

        provider.reportNewIncomingCall(with: uuid, update: update) { error in
            if let error {
                // iOS refuses a call it will not show — Do Not Disturb with this app not allowed
                // through, a device in a restricted mode, or an app that has already lost the
                // privilege. Nothing to do but say so; the obligation to report has been met.
                Log.calls.error("iOS would not show the call: \(Log.describe(error), privacy: .public)")
            }
            // CallKit answers on the queue the provider was given, which is the main one — the
            // same assertion as in the delegate methods below.
            MainActor.assumeIsolated { then() }
        }
    }

    /// Fills in who is calling, once that has been decrypted.
    func update(uuid: UUID, title: String, isVideo: Bool) {
        let update = CXCallUpdate()
        update.localizedCallerName = title
        update.hasVideo = isVideo
        provider.reportCall(with: uuid, updated: update)
    }

    /// Ends a call that was reported and turned out to have nothing behind it.
    ///
    /// Every reason maps to a different line in the system's call history, which is the whole
    /// reason they are told apart: "missed" and "answered on your iPad" are the same non-event to
    /// this app and two quite different things to the person reading their recents.
    func end(uuid: UUID, because reason: RingEnded) {
        let ended: CXCallEndedReason = switch reason {
        case .expired: .unanswered
        case .answeredElsewhere: .answeredElsewhere
        case .declinedElsewhere: .declinedElsewhere
        case .alreadyOver: .remoteEnded
        case .notACall: .failed
        }
        provider.reportCall(with: uuid, endedAt: nil, reason: ended)
    }

    /// The glyph the system draws beside the call. Optional — a call with no icon is a call.
    private static func templateIcon() -> Data? {
        // Deliberately nil for now. The app's icons are compiled into the asset catalog and
        // cannot be read back out as images — see `CLAUDE.md` on `--probe-icons`, where asking
        // for the primary icon by name does not fail politely but takes the app down. A drawn
        // template belongs with `SparkShape`, and a missing one costs nothing.
        nil
    }
}

extension CallKitService: CXProviderDelegate {
    /// The system took every call away — it does this when the provider is reset, and anything
    /// still believed to be ringing is not.
    nonisolated func providerDidReset(_ provider: CXProvider) {
        MainActor.assumeIsolated {
            AudioSession.callEnded()
            center.signedOut()
        }
    }

    /// Somebody answered.
    ///
    /// `assumeIsolated` rather than a hop onto the main actor, and it is an assertion about
    /// something already true: `setDelegate(self, queue: nil)` means CallKit delivers these on the
    /// main queue. Hopping instead would mean fulfilling the action a turn later than CallKit
    /// expects — and a `CXAction` is not `Sendable`, so it cannot make the trip anyway.
    nonisolated func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        // Pulled out before the closure: a `CXAction` is not `Sendable` and must not be
        // captured across an isolation boundary, while its UUID is a value and may.
        let uuid = action.callUUID
        MainActor.assumeIsolated {
            // Not awaited, and not activated either. The category has to be right before WebKit
            // opens the microphone, which is seconds away — the call screen has yet to load
            // Element Call — while `fulfill()` is owed to CallKit now. The queue inside
            // `AudioSession` keeps the two in order against everything else the app plays.
            Task { await AudioSession.callBegan(video: false) }
            center.answerRing(uuid)
        }
        action.fulfill()
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        let uuid = action.callUUID
        MainActor.assumeIsolated {
            center.declineRing(uuid)
            AudioSession.callEnded()
        }
        // Fulfilled before the decline has been sent. CallKit gives an action about five seconds
        // and then tears the call down regardless, and a decline that has to reach a homeserver is
        // not something to hold that deadline open for.
        action.fulfill()
    }

    nonisolated func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        // CallKit owns the activation, and this is it. Nothing to do but note it: whether WebKit's
        // own capture session and this one compose cleanly is the one thing about calls that has
        // to be watched on a real device rather than reasoned about.
        Log.calls.info("CallKit activated the audio session")
    }

    nonisolated func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        Log.calls.info("CallKit deactivated the audio session")
    }
}
#endif
