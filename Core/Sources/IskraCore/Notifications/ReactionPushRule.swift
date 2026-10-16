import Foundation
import MatrixRustSDK

/// Asking the homeserver to send a push when somebody reacts.
///
/// By default it will not, and that is not an oversight on anybody's part: the spec ships an
/// override rule, `.m.rule.reaction`, whose whole job is to swallow reactions before they ever
/// become a notification. Every Matrix client is quiet about reactions because the server is.
///
/// So this puts a rule of ours *above* it. Override rules are evaluated in order and the first
/// match wins, and a user-defined override is evaluated before the server's defaults — so a
/// reaction now matches `notify` and reaches the push gateway before `.m.rule.reaction` gets to
/// drop it.
///
/// ## Why the noise this invites is dealt with elsewhere
///
/// A push rule can see the event's type and it cannot see what the event points *at*. There is no
/// condition for "a reaction to something I wrote" — the reaction names a related event id, and
/// resolving that id means fetching another event, which a homeserver evaluating push rules will
/// not do. So this rule is necessarily broad: it notifies about every reaction in every room the
/// reader is in.
///
/// That would be intolerable on its own, and it is not left on its own. `PushDecoder` fetches the
/// message being reacted to and silences the push unless the reader wrote it. The cost of that
/// arrangement is a push that travels all the way to the device to be thrown away; the benefit is
/// that the decision is made where the facts are. It is the same shape as the rest of this app's
/// notifications, and for the same reason: the server cannot read the room.
public struct ReactionPushRule: Sendable {
    /// Ours, and named so that it is obvious in `getRawPushRules()` whose it is and what it is for.
    /// A rule id is a string on somebody's account for as long as the account exists, and an
    /// account may well be looked at by somebody debugging a different client entirely.
    static let ruleID = "moscow.swag.iskra.reactions"

    private let settings: NotificationSettings

    init(settings: NotificationSettings) {
        self.settings = settings
    }

    /// Registers the rule, or replaces the one already there.
    ///
    /// Idempotent, and called on every sign-in for that reason: the rule lives on the account
    /// rather than on the device, so the second device to sign in finds it already written, and
    /// writing it again costs one request and removes the need to ask first.
    ///
    /// Best-effort. A server that refuses this leaves the app exactly as it was before reactions
    /// were notified about at all, which is a working messenger — so the failure is a line in the
    /// log, not something anybody is stopped for.
    public func register() async {
        do {
            try await settings.setCustomPushRule(
                ruleId: Self.ruleID,
                ruleKind: .override,
                actions: [
                    .notify,
                    // Quietly. A reaction is worth knowing about and is not worth a sound: it is
                    // an answer to something already read, not a new thing to read.
                    .setTweak(value: .sound(value: ""))
                ],
                conditions: [
                    // The event type, and nothing else — see the note above on what a push rule
                    // can and cannot see.
                    .eventMatch(key: "type", pattern: "m.reaction")
                ]
            )
        } catch {
            Log.push.error("the server would not take our reaction rule: \(Log.describe(error), privacy: .public)")
        }
    }
}
