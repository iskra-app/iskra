import Foundation
import Observation
import MatrixRustSDK

/// What the account notifies about, before any one room has an opinion.
///
/// The per-room switch has been here for a while — `RoomDetailsStore.alerts`, on the chat's own
/// info screen — and it was the whole of what this app could say about notifications. That is the
/// wrong end to start from: a person who wants to be left alone by default and pulled out for
/// mentions had to open every conversation they were in and say so one at a time, and every new
/// chat undid the work.
///
/// These are **push rules on the homeserver**, not preferences on this device. Two consequences,
/// and both are things the screen has to say out loud:
///
/// - they follow the account to every client signed into it, this app's phone and Mac included;
/// - a room that has been given its own rule keeps it. Matrix resolves the room's rule first and
///   the default only where there is none, so changing a default does not quietly un-mute the
///   chat somebody muted last week. `RoomDetailsStore.setAlerts` writes the room's rule always,
///   *deliberately*, for exactly this reason.
///
/// The defaults are kept in four, not two. Matrix keys them by encrypted-or-not as well as by
/// one-to-one-or-not, because the push rule that fires is a different rule in each case. Nobody
/// thinks about their chats that way — "personal chats" and "groups" is the whole of the question
/// a person is answering — so a choice made here is written to both halves of the pair, which is
/// what stops a group coming out loud on an unencrypted room after being silenced on an encrypted
/// one.
@MainActor
@Observable
public final class NotificationRulesStore {
    /// True once the server has told us what the rules are. Until then the screen shows a spinner
    /// rather than a set of switches: every value below starts at the permissive default, and a
    /// row of switches that are all on is a confident lie about an account that may have none of
    /// them on.
    public private(set) var isLoaded = false

    /// The rules could not be read at all. Distinct from "not loaded yet", and the only one of the
    /// two the reader can do anything about.
    public private(set) var didFailToLoad = false

    /// A chat with one other person, where there is no default worth having but "tell me".
    public private(set) var directChats: RoomAlerts = .all

    /// Everything else. Kept separate because it is the one people actually change.
    public private(set) var groupChats: RoomAlerts = .all

    /// Being named. `.m.rule.is_user_mention` — the rule that fires on your display name or your
    /// Matrix ID appearing in a message.
    public private(set) var mentionsMe = true

    /// `@room`, which reaches everybody at once and is therefore the one worth being able to turn
    /// off on its own.
    public private(set) var roomMentions = true

    /// Somebody inviting you somewhere. `.m.rule.invite_for_me`.
    public private(set) var invitations = true

    /// `.m.rule.call`. There are no calls in this app yet, and the rule is still the account's:
    /// another client signed into it can ring, and this is where that is switched off.
    public private(set) var calls = true

    /// A change the homeserver would not make. Shown as an alert; the value is put back first, so
    /// the switch the reader is looking at never disagrees with the server.
    public var failure: NotificationRulesFailure?

    private let client: Client

    /// Fetched once and kept, for the same reason `RoomDetailsStore` keeps its own: the SDK builds
    /// a fresh `NotificationSettings` on every call and each one carries its own listener
    /// registration, so a screen that asked per switch would leave a trail of them.
    private var settings: NotificationSettings?

    /// The fetch, while it is in flight — the *task* rather than the result, because an `if let`
    /// followed by an `await` is not a lock. Same shape, and the same bug avoided, as
    /// `RoomDetailsStore.notificationSettings()`.
    private var fetching: Task<NotificationSettings, Never>?

    public init(client: Client) {
        self.client = client
    }

    /// Reads every rule this screen shows. Safe to call again — the screen's `.task` does, on every
    /// appearance, and re-reading is how a change made on another client turns up here.
    public func load() async {
        let settings = await notificationSettings()

        // Encrypted, because that is what this app makes: a private room in Iskra is an encrypted
        // room, and the unencrypted half of the pair exists to be *written* — see `setDefault` —
        // rather than to be asked. Asking the other half instead would report a rule almost none
        // of this account's rooms are matched by.
        let direct = await settings.getDefaultRoomNotificationMode(isEncrypted: true, isOneToOne: true)
        let group = await settings.getDefaultRoomNotificationMode(isEncrypted: true, isOneToOne: false)

        // Four calls that each throw on their own. One failure is not a reason to show none of it:
        // the switches that *were* read are true things about the account, and the screen says so
        // rather than going blank because the call rule would not answer.
        let mentionsMe = try? await settings.isUserMentionEnabled()
        let roomMentions = try? await settings.isRoomMentionEnabled()
        let invitations = try? await settings.isInviteForMeEnabled()
        let calls = try? await settings.isCallEnabled()

        self.directChats = RoomAlerts(direct)
        self.groupChats = RoomAlerts(group)
        self.mentionsMe = mentionsMe ?? self.mentionsMe
        self.roomMentions = roomMentions ?? self.roomMentions
        self.invitations = invitations ?? self.invitations
        self.calls = calls ?? self.calls

        // Everything at once failing is the shape of a server that is not answering, and the one
        // case worth a screen of its own: four switches showing their defaults over an account
        // nobody has read is worse than saying we could not read it.
        didFailToLoad = mentionsMe == nil && roomMentions == nil && invitations == nil && calls == nil
        isLoaded = true
    }

    // MARK: - Changing them

    /// The default for personal chats, or for everything else.
    ///
    /// Written to the encrypted *and* the unencrypted rule, which is the whole reason this takes
    /// `isOneToOne` rather than the four-way key the SDK does. See the note on the type.
    public func setDefault(_ choice: RoomAlerts, isOneToOne: Bool) async {
        let previous = isOneToOne ? directChats : groupChats
        guard choice != previous else { return }

        if isOneToOne { directChats = choice } else { groupChats = choice }

        let settings = await notificationSettings()
        do {
            for encrypted in [true, false] {
                try await settings.setDefaultRoomNotificationMode(isEncrypted: encrypted,
                                                                  isOneToOne: isOneToOne,
                                                                  mode: choice.mode)
            }
        } catch {
            Log.push.error("the default notification rule would not stick: \(Log.describe(error), privacy: .public)")
            if isOneToOne { directChats = previous } else { groupChats = previous }
            failure = isOneToOne ? .directDefault : .groupDefault
        }
    }

    /// Being named by somebody. See `mentionsMe`.
    public func setMentionsMe(_ enabled: Bool) async {
        await flip(\.mentionsMe, to: enabled, failing: .mention) { settings, value in
            try await settings.setUserMentionEnabled(enabled: value)
        }
    }

    /// `@room`. See `roomMentions`.
    public func setRoomMentions(_ enabled: Bool) async {
        await flip(\.roomMentions, to: enabled, failing: .roomMention) { settings, value in
            try await settings.setRoomMentionEnabled(enabled: value)
        }
    }

    /// Invitations. See `invitations`.
    public func setInvitations(_ enabled: Bool) async {
        await flip(\.invitations, to: enabled, failing: .invitation) { settings, value in
            try await settings.setInviteForMeEnabled(enabled: value)
        }
    }

    /// Calls. See `calls`.
    public func setCalls(_ enabled: Bool) async {
        await flip(\.calls, to: enabled, failing: .call) { settings, value in
            try await settings.setCallEnabled(enabled: value)
        }
    }

    /// One switch, moved at once and moved back if the server refuses.
    ///
    /// The optimism is the same as everywhere else in the app and it is not laziness: this is a
    /// control the reader has their finger on, and a switch that flicks back a second later
    /// reports the failure more clearly than one that never moved. The alert says which switch it
    /// was, because by the time it is read the switch is off again and looks untouched.
    private func flip(_ field: ReferenceWritableKeyPath<NotificationRulesStore, Bool>,
                      to enabled: Bool,
                      failing failure: NotificationRulesFailure,
                      write: (NotificationSettings, Bool) async throws -> Void) async {
        let previous = self[keyPath: field]
        guard previous != enabled else { return }
        self[keyPath: field] = enabled

        let settings = await notificationSettings()
        do {
            try await write(settings, enabled)
        } catch {
            Log.push.error("a notification rule would not stick: \(Log.describe(error), privacy: .public)")
            // Only if nothing else has moved it since. A second flip while the first was in
            // flight owns the switch, and putting the first one's old value back would undo a
            // change the reader made after it.
            if self[keyPath: field] == enabled { self[keyPath: field] = previous }
            self.failure = failure
        }
    }

    /// See `settings` and `fetching`.
    private func notificationSettings() async -> NotificationSettings {
        if let settings { return settings }
        if let fetching { return await fetching.value }

        let task = Task { [client] in await client.getNotificationSettings() }
        fetching = task

        let settings = await task.value
        self.settings = settings
        fetching = nil

        return settings
    }
}

/// A notification rule the homeserver would not change.
///
/// One case per switch rather than one sentence for all of them, for the reason every other
/// `ActionFailure` in this app is: the control has already been put back by the time the alert is
/// read, so the sentence is the only thing left that says which one it was.
public enum NotificationRulesFailure: String, CaseIterable, ActionFailure {
    case directDefault
    case groupDefault
    case mention
    case roomMention
    case invitation
    case call

    public var id: String { rawValue }

    public var explanation: LocalizedStringResource {
        switch self {
        case .directDefault: CoreStrings.NotificationRules.directFailed
        case .groupDefault: CoreStrings.NotificationRules.groupFailed
        case .mention: CoreStrings.NotificationRules.mentionFailed
        case .roomMention: CoreStrings.NotificationRules.roomMentionFailed
        case .invitation: CoreStrings.NotificationRules.invitationFailed
        case .call: CoreStrings.NotificationRules.callFailed
        }
    }
}
