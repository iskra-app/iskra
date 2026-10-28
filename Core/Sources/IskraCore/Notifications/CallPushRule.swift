import Foundation
import MatrixRustSDK

/// Asking the homeserver to stamp an incoming call so the gateway can tell it from a message.
///
/// ## The problem this exists to solve
///
/// A ringing call on iOS has to arrive as a **VoIP push**, because that is the only kind iOS wakes
/// an app for in time to ring. And since iOS 13 every delivered VoIP push must end in a call to
/// `CXProvider.reportNewIncomingCall` — miss that and the system first holds pushes back and then
/// stops delivering them to this app entirely, until it is reinstalled.
///
/// So a VoIP push must be sent for calls and for nothing else. But **Matrix push rules do not
/// route per pusher**: every pusher on the account receives every notification. Registering a
/// second pusher with a PushKit token would therefore mean a VoIP push for every "привет", and the
/// app losing the privilege within a day.
///
/// ## Why a tweak rather than a fuller payload
///
/// The obvious fix is to register the VoIP pusher without `format: .eventIdOnly`, so the gateway
/// can read the event's `type` and drop everything that is not a call. It works, and it costs the
/// gateway seeing `type`, `sender`, `room_name` and `content` **for every notifying event on the
/// account, forever** — in an unencrypted room, `content` is the message. That is precisely the
/// trade `PushRegistration` refuses in its own doc comment, made permanent to answer a yes/no
/// question about roughly one event a day.
///
/// A push rule's *actions* travel with the notification and sit in `devices[].tweaks`, **outside**
/// the stripped event metadata — so `event_id_only` does not touch them. One tweak carries exactly
/// one bit, both pushers stay `.eventIdOnly`, and the gateway learns nothing it did not already
/// know except "this one is a call".
///
/// ## Why the mark is the *sound*, of all things
///
/// It should be a custom tweak — Matrix allows them and Synapse forwards them, and
/// `Tweak.custom(name:value:)` is right there in the FFI. It cannot be, and the reason is in
/// Sygnal rather than in Matrix. Sygnal parses a notification before any pushkin sees it, and its
/// parser is this:
///
/// ```python
/// class Tweaks:
///     def __init__(self, raw):
///         self.sound = get_key(raw, "sound", str)
/// ```
///
/// It keeps `sound` and drops everything else, and `Notification` does not keep the raw payload
/// either. So a custom tweak arrives at the gateway host and is thrown away *inside the gateway
/// process*, one layer above anything we can write, and no amount of care on this side changes it.
///
/// `sound` survives, is a string, and its value is ours to choose. Hence a sound nobody will ever
/// hear: there is no `iskra.ring` file in the bundle, and the ring itself is CallKit's, not a
/// notification sound. See `Gateway/iskra_ring.py`, which reads it.
///
/// The gateway's side of the bargain is a Sygnal pushkin of ours that sends nothing to the `.voip`
/// app id unless this tweak is present. See `docs/PUSH-GATEWAY.md`.
///
/// ## Order matters
///
/// This rule is registered **before** the VoIP pusher, never after. The other way round is a VoIP
/// push for every message during the window between the two.
public struct CallPushRule: Sendable {
    /// Ours, and named so that somebody reading `getRawPushRules()` on this account — possibly
    /// while debugging a different client — can see whose it is and what it is for.
    /// Still `moscow.swag.iskra`, the app's old prefix, on purpose — the same rule as
    /// `ReactionPushRule.ruleID`: this name lives on the server, and accounts that already carry
    /// the rule would otherwise end up with two of them.
    public static let ruleID = "moscow.swag.iskra.calls"

    /// The sound value that marks a ring. Read by `Gateway/iskra_ring.py`, and written down in
    /// both places because there is no way to share a constant between a Swift app and a Python
    /// module on somebody else's server.
    ///
    /// Not a sound anybody hears: there is no such file in the bundle, and the ringing is
    /// CallKit's. It is a one-bit flag riding in the only tweak Sygnal preserves — see the note
    /// above, which is the whole story.
    public static let ringSound = "iskra.ring"

    private let settings: NotificationSettings

    init(settings: NotificationSettings) {
        self.settings = settings
    }

    /// Registers the rule, or replaces the one already there. Idempotent, and called on every
    /// sign-in for the same reason `ReactionPushRule` is: the rule lives on the account, so the
    /// second device finds it written and rewriting costs one request.
    ///
    /// Best-effort. A server that refuses it leaves the app where it was — calls that ring
    /// nowhere, which is where every Matrix client without this starts.
    public func register() async {
        do {
            try await settings.setCustomPushRule(
                ruleId: Self.ruleID,
                ruleKind: .override,
                actions: [
                    .notify,
                    // The mark, and the whole point of the rule. It is also what keeps the
                    // ordinary copy of this push quiet: iOS finds no such sound in the bundle,
                    // and the notification extension replaces the content outright anyway.
                    .setTweak(value: .sound(value: Self.ringSound))
                ],
                conditions: [
                    // A glob, and deliberately. MSC4075/4143 are still in flight, so a homeserver
                    // may write this event as `m.rtc.notification` or under an unstable
                    // `org.matrix.msc…` prefix, and a rule pinned to one spelling silently stops
                    // matching the day the server moves to the other. The tail is the part that
                    // is stable.
                    .eventMatch(key: "type", pattern: "*rtc.notification")
                ]
            )
        } catch {
            Log.push.error("the server would not take our call rule: \(Log.describe(error), privacy: .public)")
        }
    }

    /// Silences the rule — for the settings toggle that says calls should be quiet.
    ///
    /// Without this that toggle is a lie. `NotificationSettings.setCallEnabled` flips
    /// `.m.rule.call`, which matches `m.call.invite` — the *legacy* 1:1 call, not MatrixRTC — so
    /// turning calls off there leaves this rule in place and the phone goes on ringing.
    ///
    /// The rule is rewritten rather than removed, because the FFI exports no way to delete a push
    /// rule: there is `setCustomPushRule` and `getRawPushRules` and nothing between them. A rule
    /// with no actions is the spec's own way of saying "matched, and nothing happens" — and it is
    /// the better shape here anyway, because it takes the ring tweak away with it. An override
    /// that still stamped the tweak while not notifying would be a rule whose two halves disagree.
    public func silence() async {
        do {
            try await settings.setCustomPushRule(ruleId: Self.ruleID,
                                                 ruleKind: .override,
                                                 actions: [],
                                                 conditions: [
                                                     .eventMatch(key: "type", pattern: "*rtc.notification")
                                                 ])
        } catch {
            Log.push.error("the server would not quieten our call rule: \(Log.describe(error), privacy: .public)")
        }
    }
}
