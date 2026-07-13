import Foundation
import Observation
import MatrixRustSDK

/// Where a member stands in a room. Three rungs, not a number.
///
/// Matrix models this as a power level — an integer, 0 to 100, that also decides who may
/// kick whom. Showing "power level 50" beside someone's face would be leaking the data
/// model into the user's face, so the SDK's own reading of that integer is used instead
/// and everyone who is merely present gets no badge at all.
public enum RoomRole: Sendable, Equatable, CaseIterable {
    case administrator
    case moderator
    case member

    /// Administrators first, then moderators, then everyone else.
    var rank: Int {
        switch self {
        case .administrator: 0
        case .moderator: 1
        case .member: 2
        }
    }
}

/// How much weight someone carries in a room, as the *rules* see it — which is not the
/// same question as what badge they wear.
///
/// A role is three words for a reader; this is the number the homeserver will actually
/// compare when it decides whether a kick is allowed. Two administrators can both read as
/// "Administrator" and still be unable to touch each other, and in a room created under
/// version 12 the creator's level is not a number at all: it is infinite, and no amount of
/// promotion reaches it. So `unlimited` sorts above every `level`, which is the whole
/// reason this is an enum and not an `Int`.
public enum Authority: Sendable, Comparable {
    case level(Int)
    case unlimited
}

/// What this account may change about the room it is looking at.
///
/// Answered once, by the homeserver's own power levels, and then used to *hide* controls
/// rather than to grey them out. A disabled button is a promise the room will not keep —
/// it says "you could do this", and the server says otherwise. Whatever is not permitted
/// is simply not on the screen.
public struct RoomPermissions: Sendable, Equatable {
    public var canRename = false
    public var canChangeTopic = false
    public var canChangePicture = false
    public var canChangeVisibility = false
    public var canInvite = false
    public var canRemove = false
    public var canBan = false
    public var canChangeRoles = false
}
// Every field defaults to `false`, so `RoomPermissions()` is denied everything — which is
// what the screen holds before the room's power levels have arrived. That is the right way
// round: the other way, a control flickers into existence and then vanishes again once the
// room says no.

/// How loudly a room is allowed to interrupt you.
///
/// Three answers, and the middle one is the reason this is not a switch: a room you have
/// muted and a room that only speaks when it is speaking *to you* are different rooms, and
/// most group rooms want the second.
///
/// What is deliberately not offered is "follow the default". Matrix distinguishes a room
/// with no rule of its own from one whose rule happens to match the account's, and the user
/// cannot see that difference — it would be a fourth option that looks identical to
/// whichever of the three it currently resolves to. The screen shows the answer that is in
/// force, and choosing one writes it down.
public enum RoomAlerts: String, Sendable, CaseIterable, Identifiable {
    case all
    case mentions
    case muted

    public var id: String { rawValue }
}

/// A change to the room that did not happen.
///
/// One case per act, not one sentence for all of them. "Something went wrong" tells the
/// user nothing they can do; "the room would not let you remove them" tells them it was a
/// question of rights, and that the person is still in the room — which is the fact they
/// need, because the list has already been put back the way it was.
public enum RoomActionFailure: String, CaseIterable, ActionFailure {
    case rename
    case topic
    case picture
    case visibility
    case invite
    case remove
    case ban
    case role
    case leave
    case alerts

    public var id: String { rawValue }

    public var explanation: LocalizedStringResource {
        switch self {
        case .alerts: CoreStrings.RoomAction.alertsFailed
        case .rename: CoreStrings.RoomAction.renameFailed
        case .topic: CoreStrings.RoomAction.topicFailed
        case .picture: CoreStrings.RoomAction.pictureFailed
        case .visibility: CoreStrings.RoomAction.visibilityFailed
        case .invite: CoreStrings.RoomAction.inviteFailed
        case .remove: CoreStrings.RoomAction.removeFailed
        case .ban: CoreStrings.RoomAction.banFailed
        case .role: CoreStrings.RoomAction.roleFailed
        case .leave: CoreStrings.RoomAction.leaveFailed
        }
    }
}

/// One person in a room.
public struct RoomMemberSummary: Sendable, Identifiable, Equatable {
    /// The Matrix ID — "@boris:matrix.org". Also the identity, so it is the `id`.
    public let id: String
    /// What they call themselves, falling back to their Matrix ID when they have not
    /// said. Never empty.
    public let name: String
    public let avatarURL: String?
    public let role: RoomRole

    /// The number behind the role. Only ever compared, never shown.
    public let authority: Authority

    /// True when someone else in this room calls themselves the same thing.
    ///
    /// Matrix display names are not unique and are not verified, so "Boris" in a room can
    /// be two different people — which is a small, cheap impersonation. The SDK spots it;
    /// the members list then shows the Matrix ID beside the name, because the ID is the
    /// part nobody can copy.
    public let isNameAmbiguous: Bool
}

/// Everything the room-info screen shows: what the room is, who is in it, and — for
/// whoever runs the place — the means to change both.
///
/// Separate from `TimelineStore` on purpose. A conversation needs a name and a lock in
/// its header and nothing else, and it needs them on the first frame; the member list is
/// a screenful of requests that most people never open. Loading it lazily, from its own
/// store, is what keeps opening a chat cheap.
@MainActor
@Observable
public final class RoomDetailsStore {
    public private(set) var name = ""
    public private(set) var topic: String?
    public private(set) var avatarURL: String?
    public private(set) var privacy: PrivacyStatus = .unknown
    public private(set) var isDirectChat = false

    /// Whether anybody who finds the room may walk into it, or whether it takes an
    /// invitation. Read from the join rules, and `false` until they arrive — the safer of
    /// the two guesses to show for half a second.
    public private(set) var isPublic = false

    /// The other person's Matrix ID, in a chat that has exactly one other person.
    /// Nil in a room, and nil in a chat with only yourself in it.
    public private(set) var counterpartID: String?

    /// The number of people who have actually joined — not those merely invited, who are
    /// not here yet and may never be.
    public private(set) var memberCount = 0
    public private(set) var members: [RoomMemberSummary] = []
    public private(set) var isLoadingMembers = true

    public private(set) var permissions = RoomPermissions()

    /// What this room is allowed to interrupt you with. Everybody has this, whatever their
    /// power level — it is a rule about your own device, not about the room.
    public private(set) var alerts: RoomAlerts = .all

    /// Set when a change was refused. `var`, because the alert that shows it has to be
    /// able to put it back.
    public var failure: RoomActionFailure?

    /// True once we have left, so the screen can take itself down. Nothing else in the app
    /// needs telling: the room list is fed by the SDK and drops the room on its own.
    public private(set) var hasLeft = false

    private let room: Room
    private let ownUserID: String

    /// Notification rules belong to the account, not to the room — a muted room is a fact
    /// about this user's devices, and the room never hears about it. So this comes from the
    /// `Client`, which is why the store is built by `UserSession`.
    private let client: Client
    private var notifications: NotificationSettings?

    /// Where we stand in the room. Every "may I remove this person" is a comparison
    /// against this, and it is `unlimited` for nobody until the member list says so.
    private var ownAuthority = Authority.level(0)

    init(room: Room, ownUserID: String, client: Client) {
        self.room = room
        self.ownUserID = ownUserID
        self.client = client
    }

    /// Loads the room, then the people in it.
    ///
    /// In two passes, because the two have very different costs. The cached member list
    /// is already on disk and comes back at once; the fresh one is a request to the
    /// server that a large room can keep waiting. Showing the cached list first means the
    /// screen is populated immediately and then quietly corrects itself, rather than
    /// holding a spinner in front of an answer we already had.
    public func load() async {
        await loadInfo()

        if let cached = try? await room.membersNoSync() {
            apply(Self.summaries(from: cached))
        }

        if let fresh = try? await room.members() {
            apply(Self.summaries(from: fresh))
        }

        isLoadingMembers = false

        await loadPermissions()
        await loadAlerts()
    }

    /// What the room does to this device — the rule it has been given, or, if it has none,
    /// the one it inherits.
    ///
    /// The inherited answer is not a guess: the account keeps a separate default for
    /// encrypted rooms and for one-to-one chats, because those are the rooms people expect
    /// to hear from. Asking for the wrong default would show "all messages" beside a group
    /// room that is quietly on mentions-only.
    private func loadAlerts() async {
        let settings = await notificationSettings()

        if let explicit = try? await settings.getUserDefinedRoomNotificationMode(roomId: room.id()) {
            alerts = RoomAlerts(explicit)
            return
        }

        alerts = RoomAlerts(await settings.getDefaultRoomNotificationMode(isEncrypted: privacy == .protected,
                                                                          isOneToOne: isDirectChat))
    }

    /// Writes the rule down. Always explicitly, even when the choice happens to be what the
    /// room was already inheriting: the user has now said it, and a rule they chose should
    /// not change under them the day they change the account default.
    public func setAlerts(_ choice: RoomAlerts) async {
        guard choice != alerts else { return }

        let previous = alerts
        alerts = choice

        do {
            try await notificationSettings().setRoomNotificationMode(roomId: room.id(), mode: choice.mode)
        } catch {
            Log.rooms.error("the notification rule would not stick: \(String(describing: error), privacy: .public)")
            alerts = previous
            failure = .alerts
        }
    }

    /// Fetched once and kept. The SDK builds a fresh object every call, and each one carries
    /// its own listener registration — a screen that asked on every keystroke would leave a
    /// trail of them.
    private func notificationSettings() async -> NotificationSettings {
        if let notifications { return notifications }
        let settings = await client.getNotificationSettings()
        notifications = settings
        return settings
    }

    private func loadInfo() async {
        guard let info = try? await room.roomInfo() else { return }

        name = info.displayName ?? info.heroes.first?.displayName ?? String(core: CoreStrings.Room.untitled)
        topic = info.topic
        avatarURL = info.avatarUrl
        privacy = PrivacyStatus(info.encryptionState)
        isDirectChat = info.isDm
        isPublic = info.isPublic ?? false
        memberCount = Int(info.joinedMembersCount)
        counterpartID = info.isDm ? info.heroes.first(where: { $0.userId != ownUserID })?.userId : nil
    }

    /// What the room lets this account do — asked of the room, not inferred from the badge
    /// beside our own name.
    ///
    /// The badge is a summary of a number; the *rules* are a table of thresholds, one per
    /// kind of change, and a room is free to set them however it likes. A moderator in one
    /// room may rename it and in another may not, and only this table knows which.
    private func loadPermissions() async {
        guard let levels = try? await room.getPowerLevels() else { return }

        permissions = RoomPermissions(canRename: levels.canOwnUserSendState(stateEvent: .roomName),
                                      canChangeTopic: levels.canOwnUserSendState(stateEvent: .roomTopic),
                                      canChangePicture: levels.canOwnUserSendState(stateEvent: .roomAvatar),
                                      canChangeVisibility: levels.canOwnUserSendState(stateEvent: .roomJoinRules),
                                      canInvite: levels.canOwnUserInvite(),
                                      canRemove: levels.canOwnUserKick(),
                                      canBan: levels.canOwnUserBan(),
                                      canChangeRoles: levels.canOwnUserSendState(stateEvent: .roomPowerLevels))
    }

    private func apply(_ loaded: [RoomMemberSummary]) {
        guard !loaded.isEmpty else { return }

        members = loaded
        memberCount = loaded.count
        isLoadingMembers = false

        if let own = loaded.first(where: { $0.id == ownUserID }) {
            ownAuthority = own.authority
        }

        // The heroes are the server's summary of a room and can be missing; the member
        // list never is. So once it has arrived, it settles who the other person is.
        if isDirectChat, counterpartID == nil {
            counterpartID = loaded.first { $0.id != ownUserID }?.id
        }
    }

    // MARK: - Who may be touched

    /// Whether this account may act on that person at all.
    ///
    /// Two rules, and both of them are the homeserver's: you cannot remove yourself from a
    /// room by kicking yourself — leaving is a different act with a different button — and
    /// you cannot touch anybody who stands at or above your own level. The second is why
    /// `Authority` exists: two administrators are equal, so neither may demote the other,
    /// and the room's creator is above both of them forever.
    public func canManage(_ member: RoomMemberSummary) -> Bool {
        Self.canManage(member, asUser: ownUserID, holding: ownAuthority)
    }

    /// The rule itself, with nothing around it. A free function because it is the whole of
    /// the moderation logic in this app, and the only way to test it against a room the
    /// tests cannot build.
    static func canManage(_ member: RoomMemberSummary, asUser ownUserID: String, holding own: Authority) -> Bool {
        member.id != ownUserID && member.authority < own
    }

    /// The roles this account may hand to somebody else.
    ///
    /// Up to and *including* our own — Matrix lets you raise someone to your own level,
    /// and refuses to let you go past it. A promotion to something we cannot ourselves
    /// grant is a menu item that fails on the server, so it is not offered.
    public func assignableRoles(for member: RoomMemberSummary) -> [RoomRole] {
        guard permissions.canChangeRoles, canManage(member) else { return [] }
        return Self.roles(grantableBy: ownAuthority)
    }

    static func roles(grantableBy own: Authority) -> [RoomRole] {
        RoomRole.allCases.filter { authority(of: $0) <= own }
    }

    // MARK: - Changing the room

    public func rename(to newName: String) async {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != name else { return }

        let previous = name
        name = trimmed

        do {
            try await room.setName(name: trimmed)
        } catch {
            Log.rooms.error("rename refused: \(error)")
            name = previous
            failure = .rename
        }
    }

    /// An empty topic is a *deletion*, and a legitimate one — a room whose description no
    /// longer applies is better with none than with the wrong one. So this does not guard
    /// against the empty string the way `rename` does; a room with no name has nothing to
    /// call it, and a room with no topic simply says less.
    public func setTopic(_ newTopic: String) async {
        let trimmed = newTopic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != (topic ?? "") else { return }

        let previous = topic
        topic = trimmed.isEmpty ? nil : trimmed

        do {
            try await room.setTopic(topic: trimmed)
        } catch {
            Log.rooms.error("topic refused: \(error)")
            topic = previous
            failure = .topic
        }
    }

    /// The picture, as bytes. The same road the pictures in the conversation take, and for
    /// the same reason: a file written to disk so the SDK can be handed a path to it is a
    /// file somebody has to delete afterwards, and one that can be swept away mid-upload.
    public func setPicture(_ data: Data, filename: String) async {
        let info = MediaMetadata.image(data: data, filename: filename)

        do {
            try await room.uploadAvatar(mimeType: info.mimeType, data: data, mediaInfo: nil)
            await loadInfo()
        } catch {
            Log.rooms.error("room picture refused: \(error)")
            failure = .picture
        }
    }

    public func removePicture() async {
        let previous = avatarURL
        avatarURL = nil

        do {
            try await room.removeAvatar()
        } catch {
            Log.rooms.error("room picture would not clear: \(error)")
            avatarURL = previous
            failure = .picture
        }
    }

    /// Open the room to anyone who finds it, or shut it again.
    ///
    /// Matrix has more join rules than these two — knocking, restricted-to-a-space — and
    /// this app deliberately offers neither: they are answerable only in terms of the
    /// protocol, and a room set to one of them is not misrepresented here, because the
    /// switch is only shown where the rules allow it to be *set*.
    public func setPublic(_ shouldBePublic: Bool) async {
        guard shouldBePublic != isPublic else { return }

        let previous = isPublic
        isPublic = shouldBePublic

        do {
            try await room.updateJoinRules(newRule: shouldBePublic ? .public : .invite)
        } catch {
            Log.rooms.error("join rule refused: \(error)")
            isPublic = previous
            failure = .visibility
        }
    }

    // MARK: - Changing who is here

    /// Invites somebody by Matrix ID.
    ///
    /// Nothing appears in the member list on success, and that is correct: an invitation
    /// is not a membership. They show up when they accept — see `summaries(from:)`, which
    /// counts only the people who have actually joined.
    public func invite(_ userID: String) async {
        guard Self.isMatrixID(userID) else {
            failure = .invite
            return
        }

        do {
            try await room.inviteUserById(userId: userID)
        } catch {
            Log.rooms.error("invitation refused: \(error)")
            failure = .invite
        }
    }

    public func remove(_ member: RoomMemberSummary) async {
        guard permissions.canRemove, canManage(member) else { return }

        do {
            try await room.kickUser(userId: member.id, reason: nil)
            await refreshMembers()
        } catch {
            Log.rooms.error("removal refused: \(error)")
            failure = .remove
        }
    }

    /// A ban is a removal that also shuts the door. Distinct from `remove` in the room's
    /// state and in the user's head, and it is the one action here with no way back in the
    /// interface, so the screen asks before calling it.
    public func ban(_ member: RoomMemberSummary) async {
        guard permissions.canBan, canManage(member) else { return }

        do {
            try await room.banUser(userId: member.id, reason: nil)
            await refreshMembers()
        } catch {
            Log.rooms.error("ban refused: \(error)")
            failure = .ban
        }
    }

    /// Promotes or demotes somebody.
    ///
    /// The power level is the SDK's own suggestion for the role, not a number picked here:
    /// 100 and 50 are conventions, and a room that has moved them is entitled to. A
    /// creator's `infinite` cannot be assigned to anybody, which is why the `.value` case
    /// is the only one that goes through — there is no such thing as promoting someone to
    /// founder.
    public func setRole(_ role: RoomRole, for member: RoomMemberSummary) async {
        guard assignableRoles(for: member).contains(role) else { return }
        guard case .value(let level) = try? suggestedPowerLevelForRole(role: Self.sdkRole(role)) else {
            failure = .role
            return
        }

        do {
            try await room.updatePowerLevelsForUsers(updates: [UserPowerLevelUpdate(userId: member.id,
                                                                                    powerLevel: level)])
            await refreshMembers()
        } catch {
            Log.rooms.error("role change refused: \(error)")
            failure = .role
        }
    }

    /// Leaves the room. The last thing this store does.
    public func leave() async {
        do {
            try await room.leave()
            hasLeft = true
        } catch {
            Log.rooms.error("leaving refused: \(error)")
            failure = .leave
        }
    }

    /// Re-reads the member list after we have changed it.
    ///
    /// `members()`, not `membersNoSync()`: the cached list is precisely the one that has
    /// not heard about the change yet, so asking it would paint the person we just removed
    /// straight back onto the screen.
    private func refreshMembers() async {
        guard let fresh = try? await room.members() else { return }
        apply(Self.summaries(from: fresh))
    }

    // MARK: - Reading the SDK

    /// Drains the SDK's member iterator into value types the UI can diff.
    ///
    /// Only people who have joined. An invitation nobody has accepted is not a member —
    /// counting one would put a face in the list for someone who has never been in the
    /// room, and a number in the header that no one else's client agrees with.
    private static func summaries(from iterator: RoomMembersIterator) -> [RoomMemberSummary] {
        var summaries: [RoomMemberSummary] = []
        summaries.reserveCapacity(Int(iterator.len()))

        while let chunk = iterator.nextChunk(chunkSize: 100) {
            for member in chunk where member.membership == .join && !member.isServiceMember {
                summaries.append(RoomMemberSummary(id: member.userId,
                                                   name: member.displayName ?? member.userId,
                                                   avatarURL: member.avatarUrl,
                                                   role: RoomRole(member.suggestedRoleForPowerLevel),
                                                   authority: Authority(member.powerLevel),
                                                   isNameAmbiguous: member.isNameAmbiguous))
            }
        }

        // Whoever runs the room first, then everyone else by name — and by the *locale's*
        // idea of order, so a Russian room does not sort its members as if they were
        // English.
        return summaries.sorted { first, second in
            if first.role.rank != second.role.rank { return first.role.rank < second.role.rank }
            return first.name.localizedStandardCompare(second.name) == .orderedAscending
        }
    }

    /// The power level the SDK suggests for a role, as an `Authority` — so that "may I
    /// grant this?" is asked in the same currency as "does this person outrank me?".
    static func authority(of role: RoomRole) -> Authority {
        guard case .value(let level) = try? suggestedPowerLevelForRole(role: sdkRole(role)) else {
            return .unlimited
        }
        return .level(Int(level))
    }

    private static func sdkRole(_ role: RoomRole) -> RoomMemberRole {
        switch role {
        case .administrator: .administrator
        case .moderator: .moderator
        case .member: .user
        }
    }

    /// "@boris:matrix.org", and nothing else.
    ///
    /// Checked here rather than left to the server, because the failure the server gives
    /// back for a malformed ID is the same one it gives for an ID it has never heard of —
    /// and the two mean very different things to the person who typed it.
    public static func isMatrixID(_ text: String) -> Bool {
        let candidate = text.trimmingCharacters(in: .whitespaces)
        guard candidate.hasPrefix("@") else { return false }

        let parts = candidate.dropFirst().split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        return !parts[0].isEmpty && !parts[1].isEmpty && !parts[1].contains(" ")
    }
}

private extension RoomRole {
    /// A room's creator holds an infinite power level and cannot be demoted. That is a
    /// distinction the room's *rules* care about and a reader does not: both run the
    /// place, so both read as an administrator.
    init(_ role: RoomMemberRole) {
        switch role {
        case .creator, .administrator: self = .administrator
        case .moderator: self = .moderator
        default: self = .member
        }
    }
}

extension RoomAlerts {
    /// The SDK's word for the same three answers. `internal`, and deliberately: the enum
    /// above is what the app talks in, and `RoomNotificationMode` does not leave `IskraCore`.
    var mode: RoomNotificationMode {
        switch self {
        case .all: .allMessages
        case .mentions: .mentionsAndKeywordsOnly
        case .muted: .mute
        }
    }

    init(_ mode: RoomNotificationMode) {
        switch mode {
        case .allMessages: self = .all
        case .mentionsAndKeywordsOnly: self = .mentions
        case .mute: self = .muted
        }
    }
}

private extension Authority {
    init(_ level: PowerLevel) {
        switch level {
        case .infinite: self = .unlimited
        case .value(let value): self = .level(Int(value))
        }
    }
}
