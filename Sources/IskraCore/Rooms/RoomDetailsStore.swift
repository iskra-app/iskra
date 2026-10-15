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
    /// Who may read what was said before they came — `m.room.history_visibility`.
    public var canChangeHistory = false
    /// The room's `#address:server`, and whether the server lists it in its directory.
    public var canChangeAddress = false
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
    /// A rule of the room — who may write, invite, remove — that would not change.
    case rules
    case leave
    case alerts

    /// The room itself would not open, so there is nothing on the screen to change. Its own case
    /// because it is the only one that is not about an act the user performed: they pressed nothing
    /// and nothing was refused — the room simply could not be read.
    case load

    /// An invitation that would not be taken up. Its own sentence rather than `leave`'s or
    /// `invite`'s: the user pressed "Join" and is looking at a room they are still not in.
    case acceptInvite
    /// And one that would not be turned down — which matters more than it sounds, because the user
    /// believes they are rid of it and it is still there.
    case declineInvite

    /// A pin (the `m.favourite` tag) that would not take. The user dragged a chat to the top and it
    /// slid back — worth saying, because a pin is a small promise that a room stays where you put it.
    case pin
    /// An archive (the `m.lowpriority` tag) that would not take. The user swept a room away and it
    /// is still sitting in the list.
    case archive
    /// A read/unread flag that would not change. One case for both directions: the act is the same
    /// shape either way, and the sentence — "the read state would not change" — fits both.
    case read
    /// A report that did not reach the moderators. The user flagged something abusive and needs to
    /// know it did not go through, or they will assume it is handled.
    case report
    /// A blocked person who could not be let back.
    case unban
    /// Who may read the history did not change.
    case history
    /// The address could not be set or taken off.
    case address
    /// The address is somebody else's already — its own sentence, because it is the one failure
    /// here the user fixes by typing something else rather than by trying again.
    case addressTaken
    /// The room could not be put in the server's list, or taken out of it.
    case directory

    public var id: String { rawValue }

    public var explanation: LocalizedStringResource {
        switch self {
        case .load: CoreStrings.RoomAction.loadFailed
        case .alerts: CoreStrings.RoomAction.alertsFailed
        case .rename: CoreStrings.RoomAction.renameFailed
        case .topic: CoreStrings.RoomAction.topicFailed
        case .picture: CoreStrings.RoomAction.pictureFailed
        case .visibility: CoreStrings.RoomAction.visibilityFailed
        case .invite: CoreStrings.RoomAction.inviteFailed
        case .remove: CoreStrings.RoomAction.removeFailed
        case .ban: CoreStrings.RoomAction.banFailed
        case .role: CoreStrings.RoomAction.roleFailed
        case .rules: CoreStrings.RoomAction.rulesFailed
        case .leave: CoreStrings.RoomAction.leaveFailed
        case .acceptInvite: CoreStrings.RoomAction.acceptInviteFailed
        case .declineInvite: CoreStrings.RoomAction.declineInviteFailed
        case .pin: CoreStrings.RoomAction.pinFailed
        case .archive: CoreStrings.RoomAction.archiveFailed
        case .read: CoreStrings.RoomAction.readFailed
        case .report: CoreStrings.RoomAction.reportFailed
        case .unban: CoreStrings.RoomAction.unbanFailed
        case .history: CoreStrings.RoomAction.historyFailed
        case .address: CoreStrings.RoomAction.addressFailed
        case .addressTaken: CoreStrings.RoomAction.addressTaken
        case .directory: CoreStrings.RoomAction.directoryFailed
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

public extension RoomMemberSummary {
    /// Somebody met outside any room — a QR code, a link. They have no role anywhere this screen
    /// could speak of, so they are an ordinary member of nothing in particular.
    init(person: PersonProfile) {
        self.init(id: person.id, name: person.name, avatarURL: person.avatarURL,
                  role: .member, authority: .level(0), isNameAmbiguous: false)
    }
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

    /// What the *server* calls this chat: the other person's display name, or the room's own. Kept
    /// beside `name` because the two come apart the moment somebody renames a personal chat on
    /// this device — see `LocalNames`. The edit field shows this as its placeholder, which is how
    /// a chat with a nickname still says who it is really with.
    public private(set) var serverName = ""
    public private(set) var topic: String?
    public private(set) var avatarURL: String?

    /// What a generated stand-in face for this room is computed from, when there is no picture.
    /// The room's own ID, or the other person's in a personal chat — the same rule the chat list
    /// follows, so the portrait at the top of this screen is the face from the row that opened it.
    /// Nil until the room info has arrived: an empty seed is a valid string and would
    /// draw a creature of its own, so the face would change once, visibly, on load.
    public private(set) var avatarSeed: String?
    /// A group's few named members, for the cluster at the top of the screen — the same faces the
    /// row that opened it showed. See `RoomSummary.faces`.
    public private(set) var faces: [RoomFace] = []
    public private(set) var privacy: PrivacyStatus = .unknown
    /// What this room is — personal chat, group, or space. See `RoomKind`. This is what the
    /// screen should ask when it decides whether to call the room a room: a personal chat with
    /// a third person invited into it is still a personal chat.
    public private(set) var kind: RoomKind = .group

    /// Exactly one other person here right now. About the room's present membership, not about
    /// what it is — the notification defaults are asked in these terms, and so is the header.
    public private(set) var isOneToOne = false

    /// Whether anybody who finds the room may walk into it, or whether it takes an
    /// invitation. Read from the join rules, and `false` until they arrive — the safer of
    /// the two guesses to show for half a second.
    public private(set) var isPublic = false
    /// The room's published address, `#name:server`, when it has one — what a link to it is made of.
    public private(set) var canonicalAlias: String?

    /// Who may read what was said before they arrived. See `HistoryAccess`.
    public private(set) var history: HistoryAccess = .shared

    /// Whether the server lists the room in its directory — the "Public rooms" search. Not the same
    /// as `isPublic`: a room anybody may walk into can still be one nobody finds without the link.
    /// Nil until asked, because only the server knows and it is asked only by the screen that
    /// changes it.
    public private(set) var isInDirectory: Bool?

    /// The server addresses for this room are made on: the part after the colon of our own ID.
    public var addressServer: String {
        String(ownUserID.drop { $0 != ":" }.dropFirst())
    }

    /// People shut out of the room, for whoever may let them back. See `unban`.
    public private(set) var banned: [RoomMemberSummary] = []

    /// The other person's Matrix ID, in a chat that has exactly one other person.
    /// Nil in a room, and nil in a chat with only yourself in it.
    public private(set) var counterpartID: String?

    /// The number of people who have actually joined — not those merely invited, who are
    /// not here yet and may never be.
    public private(set) var memberCount = 0
    public private(set) var members: [RoomMemberSummary] = []
    public private(set) var isLoadingMembers = true

    public private(set) var permissions = RoomPermissions()

    /// Who may do what here, by role — the table behind `permissions`, for the screen that changes
    /// it. Nil until the power levels have been read.
    public private(set) var rules: RoomRules?

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

    /// The room's other addresses, kept so that changing the main one does not drop them.
    private var alternativeAliases: [String] = []

    /// The room telling us it has changed. Kept alive because dropping it unsubscribes — see
    /// `stop()`, and see `load()` for why this screen needs one at all.
    private var infoHandle: TaskHandle?

    /// Which showing of the screen `load()` is working for. `stop()` moves it on, and a load that
    /// wakes from an await to find it moved subscribes to nothing: the screen it was loading for
    /// has closed, and a subscription made now would have nobody left to cancel it.
    private var generation = 0

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
        self.roomID = room.id()

        // The screen that sets a nickname is this one, so it is also the one that has to notice.
        // Nothing syncs and no `RoomInfo` arrives: this is the whole of how the portrait at the
        // top changes when the field underneath it does.
        localNameObserver = LocalNames.observe { [weak self] changed in
            guard let self, changed == nil || changed == self.roomID else { return }
            self.name = LocalNames.name(for: self.roomID) ?? self.serverName
        }
    }

    /// The room this is about. Public because the screen needs it to set a nickname, which is a
    /// fact about a room ID and not about anything the server knows.
    public let roomID: String

    /// The name this device has been told to use for this chat, if any — the field's own value,
    /// as opposed to `name`, which is whatever ends up on screen.
    public var localName: String? { LocalNames.name(for: roomID) }

    /// Renaming the person at the other end of a personal chat, on this device and nowhere else.
    ///
    /// Not `room.setName`, which is the protocol's answer and the wrong one: that writes an
    /// `m.room.name` state event into a two-person room, where the other person receives it, sees
    /// it, and can change it back. What somebody privately calls a friend is not an announcement
    /// to that friend. See `LocalNames` for where it goes instead and what that costs.
    ///
    /// Given nil or blank, the real name comes back.
    public func renameLocally(to name: String?) {
        LocalNames.set(name, for: roomID)
    }

    /// The subscription to that happening. Held because dropping it unsubscribes.
    private var localNameObserver: LocalNameSubscription?

    /// Loads the room, then the people in it.
    ///
    /// In two passes, because the two have very different costs. The cached member list
    /// is already on disk and comes back at once; the fresh one is a request to the
    /// server that a large room can keep waiting. Showing the cached list first means the
    /// screen is populated immediately and then quietly corrects itself, rather than
    /// holding a spinner in front of an answer we already had.
    public func load() async {
        // Whether the room itself could be read at all. Everything below is a detail *of* the room,
        // and asking for details of a room we could not open produces a screen that is not empty
        // but *wrong*: a blank name, "not protected" where the room is encrypted, no members, and
        // a notification rule looked up with the wrong defaults because `privacy` never arrived.
        //
        // Five `try?` in a row used to make all of that indistinguishable from a room that is
        // genuinely quiet, with no failure recorded anywhere — while the field for exactly that
        // (`failure`) and the alert that shows it both already existed, three lines up.
        let generation = self.generation
        let succeeded = await loadInfo()
        guard generation == self.generation else { return }
        guard succeeded else {
            isLoadingMembers = false
            didFailToLoad = true
            failure = .load
            return
        }

        // And then keep it up to date, which this screen used not to do.
        //
        // The room's name and picture had two sources of truth: the header above the conversation
        // is fed by `TimelineStore`, which subscribes and follows the room as it changes, and this
        // screen took a single snapshot with `roomInfo()` and held it. So renaming the room from
        // another device while its info screen was open updated the header behind the screen and
        // never the screen itself — and the field the user was looking at, which is the field they
        // would have edited, showed a name the room no longer had.
        //
        // The same subscription, and the same `adopt`, so the two cannot drift again.
        infoHandle = room.subscribeToRoomInfoUpdates(listener: RoomInfoUpdates { [weak self] info in
            Task { @MainActor [weak self] in
                self?.adopt(info)
            }
        })

        if let cached = try? await room.membersNoSync() {
            guard generation == self.generation else { return }
            apply(Self.partition(cached))
        }

        if let fresh = try? await room.members() {
            guard generation == self.generation else { return }
            apply(Self.partition(fresh))
        }

        guard generation == self.generation else { return }
        isLoadingMembers = false

        await loadPermissions()
        await loadAlerts()
    }

    /// The room could not be read. Distinct from a room with nothing in it, and the only one of the
    /// two the user can do anything about.
    public private(set) var didFailToLoad = false

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
                                                                          isOneToOne: isOneToOne))
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
            Log.rooms.error("the notification rule would not stick: \(Log.describe(error), privacy: .public)")
            rollBack(\.alerts, to: previous, ifStillEqualTo: choice)
            failure = .alerts
        }
    }

    /// Fetched once and kept. The SDK builds a fresh object every call, and each one carries
    /// its own listener registration — a screen that asked on every keystroke would leave a
    /// trail of them.
    private func notificationSettings() async -> NotificationSettings {
        if let notifications { return notifications }

        // The `await` below is where two callers meet. `loadAlerts` asks for this, and so does every
        // change to the room's alerts, and an `if let` followed by an `await` is not a lock: both
        // callers see nil, both go to the SDK, and the second one to come back overwrites the first
        // — which leaves two `NotificationSettings` objects alive, each with its own listener
        // registration. That is the exact duplication the cache was introduced to prevent, and
        // caching the *task* rather than the result is what actually prevents it: the second caller
        // finds the first one's work in flight and waits for it.
        if let fetching { return await fetching.value }

        let task = Task { await client.getNotificationSettings() }
        fetching = task

        let settings = await task.value
        notifications = settings
        fetching = nil

        return settings
    }

    /// The fetch for `notifications`, while it is in flight. See `notificationSettings()`.
    private var fetching: Task<NotificationSettings, Never>?

    /// Reads the room. False when it could not be read, which is a thing the caller has to know:
    /// everything else on this screen is a detail of a room that may not have opened.
    @discardableResult
    private func loadInfo() async -> Bool {
        guard let info = try? await room.roomInfo() else {
            Log.rooms.error("the room would not open")
            return false
        }

        adopt(info)
        return true
    }

    /// What the room says about itself, whether we asked just now or the SDK volunteered it.
    ///
    /// One function, called from both, deliberately: the first read and every update afterwards
    /// must produce the same fields from the same `RoomInfo`, or the screen would change its mind
    /// about what the room is called the moment somebody else changed something unrelated.
    private func adopt(_ info: RoomInfo) {
        name = info.title(besides: ownUserID)
        serverName = info.serverTitle(besides: ownUserID)
        topic = info.topic
        // The other person's picture in a personal chat, exactly as the name above it. See
        // `RoomInfo.pictureURL` — a one-to-one room almost never has an avatar of its own.
        avatarURL = info.pictureURL(besides: ownUserID)
        avatarSeed = info.avatarSeed(besides: ownUserID)
        faces = info.kind == .group ? info.faces(besides: ownUserID) : []
        privacy = PrivacyStatus(info.encryptionState)
        kind = info.kind
        isOneToOne = info.isOneToOne
        isPublic = info.isPublic ?? false
        canonicalAlias = info.canonicalAlias
        alternativeAliases = info.alternativeAliases
        history = HistoryAccess(info.historyVisibility)
        memberCount = Int(info.joinedMembersCount)
        counterpartID = isOneToOne ? info.counterpart(besides: ownUserID)?.userId : nil
        // The rules follow the room like its name does: a moderator handed a power from another
        // device sees it here without reopening the screen, and a rule changed on *this* screen is
        // confirmed by the room's own echo rather than by re-reading a cache that has not heard yet.
        if let levels = info.powerLevels { adopt(levels) }
    }

    /// Closing the screen. Kept alive by the handle, and dropping the handle is what unsubscribes —
    /// so this is not tidiness, it is the difference between a listener that ends with the screen
    /// and one that runs until the account is signed out.
    public func stop() {
        generation += 1
        infoHandle?.cancel()
        infoHandle = nil
    }

    /// What the room lets this account do — asked of the room, not inferred from the badge
    /// beside our own name.
    ///
    /// The badge is a summary of a number; the *rules* are a table of thresholds, one per
    /// kind of change, and a room is free to set them however it likes. A moderator in one
    /// room may rename it and in another may not, and only this table knows which.
    private func loadPermissions() async {
        guard let levels = try? await room.getPowerLevels() else { return }
        adopt(levels)
    }

    private func adopt(_ levels: RoomPowerLevels) {
        permissions = RoomPermissions(canRename: levels.canOwnUserSendState(stateEvent: .roomName),
                                      canChangeTopic: levels.canOwnUserSendState(stateEvent: .roomTopic),
                                      canChangePicture: levels.canOwnUserSendState(stateEvent: .roomAvatar),
                                      canChangeVisibility: levels.canOwnUserSendState(stateEvent: .roomJoinRules),
                                      canInvite: levels.canOwnUserInvite(),
                                      canRemove: levels.canOwnUserKick(),
                                      canBan: levels.canOwnUserBan(),
                                      canChangeRoles: levels.canOwnUserSendState(stateEvent: .roomPowerLevels),
                                      canChangeHistory: levels.canOwnUserSendState(stateEvent: .roomHistoryVisibility),
                                      canChangeAddress: levels.canOwnUserSendState(stateEvent: .roomCanonicalAlias))
        rules = RoomRules(levels.values())
    }

    private func apply(_ loaded: (joined: [RoomMemberSummary], banned: [RoomMemberSummary])) {
        banned = loaded.banned
        apply(loaded.joined)
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
        if isOneToOne, counterpartID == nil {
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

    nonisolated static func roles(grantableBy own: Authority) -> [RoomRole] {
        RoomRole.allCases.filter { authority(of: $0) <= own }
    }

    /// The people who run the room — administrators and moderators, in the list's order.
    public var staff: [RoomMemberSummary] {
        members.filter { $0.role != .member }
    }

    /// The roles this account may set a rule to — none at all when the rule is out of its reach.
    ///
    /// The homeserver's two rules again, applied to thresholds instead of people: you may not move
    /// a threshold that stands above you, and you may not raise one past yourself. An administrator
    /// can therefore hand banning to moderators and take it back, and a moderator cannot touch it.
    public func roles(for rule: RoomRule) -> [RoomRole] {
        guard let rules, permissions.canChangeRoles else { return [] }
        return Self.roles(for: rule, in: rules, holding: ownAuthority)
    }

    nonisolated static func roles(for rule: RoomRule, in rules: RoomRules, holding own: Authority) -> [RoomRole] {
        guard .level(rules.levels[rule] ?? 0) <= own else { return [] }
        return roles(grantableBy: own)
    }

    /// Changes who may do one thing. Shown at once and put back if the room says no.
    public func setRule(_ rule: RoomRule, to role: RoomRole) async {
        guard roles(for: rule).contains(role), let before = rules,
              case let .level(level) = Self.authority(of: role) else { return }
        guard before.role(for: rule) != role else { return }

        var levels = before.levels
        levels[rule] = level
        rules = RoomRules(levels: levels)

        do {
            // Not re-read here: the room's cache has not heard of the change until the next sync,
            // and re-reading it put the old answer back on the screen. The room's echo arrives
            // through `adopt(_ info:)`.
            try await room.applyPowerLevelChanges(changes: rule.change(to: Int64(level)))
        } catch {
            Log.rooms.error("rule change refused: \(Log.describe(error), privacy: .public)")
            if rules?.levels[rule] == level { rules = before }
            failure = .rules
        }
    }

    // MARK: - Changing the room

    /// Puts a value back — but only if it is still the value we put there.
    ///
    /// Every optimistic edit in this file has the same skeleton: show the new value at once, send
    /// it, and put the old one back if the server says no. The rollback was unconditional, and that
    /// is a race with a plain outcome: rename to A, rename to B before A has answered, A fails —
    /// and the name goes back to what it was *before A*, discarding B, which succeeded. The user's
    /// most recent decision is the one that gets thrown away.
    ///
    /// So a rollback is a compare-and-set: undo the edit only if nothing has happened since. If
    /// something has, that something is newer and is the truth, and the failed edit has nothing
    /// left to say.
    private func rollBack<T: Equatable>(_ keyPath: ReferenceWritableKeyPath<RoomDetailsStore, T>,
                                        to previous: T,
                                        ifStillEqualTo attempted: T) {
        guard self[keyPath: keyPath] == attempted else { return }
        self[keyPath: keyPath] = previous
    }

    public func rename(to newName: String) async {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != name else { return }

        let previous = name
        name = trimmed

        do {
            try await room.setName(name: trimmed)
        } catch {
            Log.rooms.error("rename refused: \(Log.describe(error), privacy: .public)")
            rollBack(\.name, to: previous, ifStillEqualTo: trimmed)
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
        let attempted: String? = trimmed.isEmpty ? nil : trimmed
        topic = attempted

        do {
            try await room.setTopic(topic: trimmed)
        } catch {
            Log.rooms.error("topic refused: \(Log.describe(error), privacy: .public)")
            rollBack(\.topic, to: previous, ifStillEqualTo: attempted)
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
            Log.rooms.error("room picture refused: \(Log.describe(error), privacy: .public)")
            failure = .picture
        }
    }

    public func removePicture() async {
        let previous = avatarURL
        avatarURL = nil

        do {
            try await room.removeAvatar()
        } catch {
            Log.rooms.error("room picture would not clear: \(Log.describe(error), privacy: .public)")
            rollBack(\.avatarURL, to: previous, ifStillEqualTo: nil)
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
            Log.rooms.error("join rule refused: \(Log.describe(error), privacy: .public)")
            rollBack(\.isPublic, to: previous, ifStillEqualTo: shouldBePublic)
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
            Log.rooms.error("invitation refused: \(Log.describe(error), privacy: .public)")
            failure = .invite
        }
    }

    /// Invites several people, one after another, and answers with the ones the server refused.
    ///
    /// Sets no `failure` of its own: the screen that asks is a sheet over this store's screen, and
    /// an alert raised from under a sheet is an alert nobody sees. The sheet says it instead, and
    /// keeps the refused people chosen so that "again" is one press.
    public func invite(_ userIDs: [String]) async -> [String] {
        var refused: [String] = []
        for userID in userIDs {
            guard Self.isMatrixID(userID) else {
                refused.append(userID)
                continue
            }
            do {
                try await room.inviteUserById(userId: userID)
            } catch {
                Log.rooms.error("invitation refused: \(Log.describe(error), privacy: .public)")
                refused.append(userID)
            }
        }
        return refused
    }

    public func remove(_ member: RoomMemberSummary) async {
        guard permissions.canRemove, canManage(member) else { return }

        do {
            try await room.kickUser(userId: member.id, reason: nil)
            await refreshMembers()
        } catch {
            Log.rooms.error("removal refused: \(Log.describe(error), privacy: .public)")
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
            // On the screen at once — out of the members, onto the list of the blocked — and then
            // read back once the room has heard of it. See `settle`.
            members.removeAll { $0.id == member.id }
            if !banned.contains(where: { $0.id == member.id }) { banned.append(member) }
            await settle(member.id, isBanned: true)
        } catch {
            Log.rooms.error("ban refused: \(Log.describe(error), privacy: .public)")
            failure = .ban
        }
    }

    /// Lets somebody back: the ban is lifted, and they are free to come in again — not brought
    /// in. Matrix asks the same power of this as of the ban itself.
    public func unban(_ member: RoomMemberSummary) async {
        guard permissions.canBan else { return }

        let previous = banned
        banned.removeAll { $0.id == member.id }
        do {
            try await room.unbanUser(userId: member.id, reason: nil)
            await settle(member.id, isBanned: false)
        } catch {
            Log.rooms.error("unban refused: \(Log.describe(error), privacy: .public)")
            banned = previous
            failure = .unban
        }
    }

    // MARK: - History and address

    /// Who may read what was said before they came.
    public func setHistory(_ visibility: HistoryAccess) async {
        guard permissions.canChangeHistory, visibility != history else { return }
        let previous = history
        history = visibility
        do {
            try await room.updateHistoryVisibility(visibility: visibility.sdk)
        } catch {
            Log.rooms.error("history visibility refused: \(Log.describe(error), privacy: .public)")
            rollBack(\.history, to: previous, ifStillEqualTo: visibility)
            failure = .history
        }
    }

    /// Asks the server whether the room is in its directory. Only the screen that changes it asks.
    public func loadDirectory() async {
        guard let visibility = try? await room.getRoomVisibility() else { return }
        if case .public = visibility { isInDirectory = true } else { isInDirectory = false }
    }

    public func setInDirectory(_ listed: Bool) async {
        guard permissions.canChangeAddress, listed != isInDirectory else { return }
        let previous = isInDirectory
        isInDirectory = listed
        do {
            try await room.updateRoomVisibility(visibility: listed ? .public : .private)
        } catch {
            Log.rooms.error("directory listing refused: \(Log.describe(error), privacy: .public)")
            isInDirectory = previous
            failure = .directory
        }
    }

    /// Gives the room the address `#name:server`, or takes it away when `name` is empty.
    ///
    /// Two things on the server, in this order: the address is claimed in the server's alias table
    /// (`publishRoomAliasInRoomDirectory` — a misleading name: it is the alias, not the room list),
    /// and only then named in the room's state as its main address. The other way round would put
    /// in the room an address that points nowhere, or at somebody else's room. A claim that comes
    /// back `false` is an address already taken, and that is said in so many words.
    ///
    /// The old address is let go of afterwards, so a renamed room does not keep its old name
    /// reserved for ever — but only if it was this server's to let go.
    public func setAddress(_ name: String) async {
        guard permissions.canChangeAddress else { return }
        let local = Self.addressName(name)
        let alias = local.isEmpty ? nil : "#\(local):\(addressServer)"
        guard alias != canonicalAlias else { return }
        if let alias, !isRoomAliasFormatValid(alias: alias) {
            failure = .address
            return
        }

        let previous = canonicalAlias
        do {
            if let alias {
                guard try await room.publishRoomAliasInRoomDirectory(alias: alias) else {
                    failure = .addressTaken
                    return
                }
            }
            try await room.updateCanonicalAlias(alias: alias,
                                                altAliases: alternativeAliases.filter { $0 != alias })
            canonicalAlias = alias
            if let previous, previous.hasSuffix(":\(addressServer)") {
                _ = try? await room.removeRoomAliasFromRoomDirectory(alias: previous)
            }
        } catch {
            Log.rooms.error("address refused: \(Log.describe(error), privacy: .public)")
            failure = .address
        }
    }

    /// What an address may be made of, from whatever was typed: the SDK's own rule for turning a
    /// room's name into one — lower case, dashes for spaces, nothing a URL would choke on. A typed
    /// `#` or `:server` is forgiven, because people paste whole addresses.
    nonisolated public static func addressName(_ typed: String) -> String {
        var text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        if let colon = text.firstIndex(of: ":") { text = String(text[..<colon]) }
        return text.isEmpty ? "" : roomAliasNameFromRoomDisplayName(roomName: text)
    }

    /// The name of the address, without the `#` and the server — what the field shows.
    public var addressName: String {
        guard let alias = canonicalAlias else { return "" }
        return String(alias.dropFirst().prefix { $0 != ":" })
    }

    /// Promotes or demotes somebody.
    ///
    /// The power level is the SDK's own suggestion for the role. This used to claim that "a room
    /// that has moved them is entitled to" — which reads as though the room's own table were
    /// consulted somewhere, and it is not, and it *cannot be*: Matrix has no such table. A power
    /// level is an integer, `m.room.power_levels` names thresholds for **acts** (ban, kick, invite,
    /// redact) and nowhere names a threshold for a *role*. "Administrator is 100, moderator is 50"
    /// is a convention that clients share, not a fact a room can state — so `suggestedPowerLevelForRole`
    /// is not a fallback here, it is the only honest source there is, and every other Matrix client
    /// writes the same numbers.
    ///
    /// A creator's `infinite` cannot be assigned to anybody, which is why the `.value` case is the
    /// only one that goes through — there is no such thing as promoting someone to founder.
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
            Log.rooms.error("role change refused: \(Log.describe(error), privacy: .public)")
            failure = .role
        }
    }

    /// Leaves the room. The last thing this store does.
    public func leave() async {
        do {
            try await room.leave()
            hasLeft = true
        } catch {
            Log.rooms.error("leaving refused: \(Log.describe(error), privacy: .public)")
            failure = .leave
        }
    }

    /// Re-reads the members until the room agrees that `userID` is, or is no longer, blocked.
    ///
    /// A ban is accepted by the server long before this device's copy of the room hears of it: the
    /// change comes back through sync, and until then `members()` answers from a store that has not
    /// seen it — a list with the blocked person still in it, read straight back over the screen
    /// that had just taken them off. So the list is read a few times, briefly, and the first answer
    /// that has caught up is the one kept. One that never does leaves the screen as it was put.
    private func settle(_ userID: String, isBanned: Bool) async {
        let generation = self.generation
        for _ in 0..<Self.settleAttempts {
            guard let fresh = try? await room.members() else { return }
            let loaded = Self.partition(fresh)
            guard generation == self.generation else { return }
            if loaded.banned.contains(where: { $0.id == userID }) == isBanned {
                apply(loaded)
                return
            }
            try? await Task.sleep(for: .milliseconds(400))
        }
    }

    private static let settleAttempts = 10

    /// Re-reads the member list after we have changed it.
    ///
    /// `members()`, not `membersNoSync()`: the cached list is precisely the one that has
    /// not heard about the change yet, so asking it would paint the person we just removed
    /// straight back onto the screen.
    private func refreshMembers() async {
        guard let fresh = try? await room.members() else { return }
        apply(Self.partition(fresh))
    }

    // MARK: - Reading the SDK

    /// Drains the SDK's member iterator into value types the UI can diff.
    ///
    /// Only people who have joined. An invitation nobody has accepted is not a member —
    /// counting one would put a face in the list for someone who has never been in the
    /// room, and a number in the header that no one else's client agrees with.
    static func summaries(from iterator: RoomMembersIterator) -> [RoomMemberSummary] {
        partition(iterator).joined
    }

    /// The members, and apart from them the people the room has shut out — one pass, because an
    /// iterator is drained once.
    static func partition(_ iterator: RoomMembersIterator) -> (joined: [RoomMemberSummary], banned: [RoomMemberSummary]) {
        var summaries: [RoomMemberSummary] = []
        var banned: [RoomMemberSummary] = []
        summaries.reserveCapacity(Int(iterator.len()))

        while let chunk = iterator.nextChunk(chunkSize: 100) {
            for member in chunk where !member.isServiceMember {
                let summary = RoomMemberSummary(id: member.userId,
                                                name: member.displayName ?? member.userId,
                                                avatarURL: member.avatarUrl,
                                                role: RoomRole(member.suggestedRoleForPowerLevel),
                                                authority: Authority(member.powerLevel),
                                                isNameAmbiguous: member.isNameAmbiguous)
                switch member.membership {
                case .join: summaries.append(summary)
                case .ban: banned.append(summary)
                default: break
                }
            }
        }
        banned.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        // Whoever runs the room first, then everyone else by name — and by the *locale's*
        // idea of order, so a Russian room does not sort its members as if they were
        // English.
        let joined = summaries.sorted { first, second in
            if first.role.rank != second.role.rank { return first.role.rank < second.role.rank }
            return first.name.localizedStandardCompare(second.name) == .orderedAscending
        }
        return (joined, banned)
    }

    /// The power level the SDK suggests for a role, as an `Authority` — so that "may I
    /// grant this?" is asked in the same currency as "does this person outrank me?".
    nonisolated static func authority(of role: RoomRole) -> Authority {
        guard case .value(let level) = try? suggestedPowerLevelForRole(role: sdkRole(role)) else {
            return .unlimited
        }
        return .level(Int(level))
    }

    nonisolated private static func sdkRole(_ role: RoomRole) -> RoomMemberRole {
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
    nonisolated public static func isMatrixID(_ text: String) -> Bool {
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
