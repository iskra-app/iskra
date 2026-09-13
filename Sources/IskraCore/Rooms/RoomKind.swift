import Foundation
import MatrixRustSDK

/// What a room *is*: a conversation with one person, a conversation with several, or a
/// container for other rooms.
///
/// One question asked in one place, because the answer used to be reassembled from flags at
/// every screen that needed it — and the flags do not mean what they look like. A group with
/// two people in it is a group; a personal chat that a third person was invited into is still
/// a personal chat. Neither is decided by counting heads.
public enum RoomKind: String, Sendable, Equatable, Hashable, Codable {
    /// Not a chat at all — a space, which is a room whose contents are other rooms.
    case space
    /// Started as a conversation with one person: `is_direct` on the invitation, and the room
    /// listed in the account's `m.direct`.
    case direct
    /// Everything else.
    case group
}

extension RoomKind {
    /// The order matters. A space is a room too, and asking it whether it is personal or group
    /// is a question with no right answer — so it is settled first and never reaches the other
    /// two.
    init(_ info: RoomInfo) {
        if info.isSpace {
            self = .space
        } else if info.isDirect {
            self = .direct
        } else {
            self = .group
        }
    }
}

/// The room as the screens need it. Internal on purpose: `RoomInfo` is an SDK type, and nothing
/// above `IskraCore` is allowed to see one.
extension RoomInfo {
    var kind: RoomKind { RoomKind(self) }

    /// There is exactly one other person here *right now*.
    ///
    /// Deliberately not the same question as `kind == .direct`, and the two answer different
    /// screens. This one is about layout — whether a face and a name belong above every
    /// incoming message — and it changes the moment somebody else is invited in. What the room
    /// *is* does not.
    ///
    /// The counts are zero for a room the client has not synced yet, and "zero people" is not
    /// an answer; there the SDK's own summary is the better guess.
    var isOneToOne: Bool {
        guard isDirect else { return false }
        let people = joinedMembersCount + invitedMembersCount
        return people == 0 ? isDm : people <= 2
    }

    /// The other person, as the server summarises them.
    ///
    /// The heroes are the server's shorthand for a room with no name of its own, and they
    /// normally leave the current user out — normally, not always, and a chat with nobody but
    /// yourself in it has only you. Filtering keeps your own face and your own name out of a
    /// conversation that is supposed to be with somebody else.
    func counterpart(besides ownUserID: String?) -> RoomHero? {
        heroes.first { $0.userId != ownUserID }
    }

    /// What to call the room on screen.
    ///
    /// A room with no name is normal in Matrix — most personal chats have none — so this falls
    /// back to whoever is in it rather than showing a raw room ID to a human.
    ///
    /// And above all of that sits the name this device was told to use, in a personal chat where
    /// the user has given one: see `LocalNames`. It is applied *here*, at the single place a room
    /// gets its name, rather than at each of the screens that show one — the list, the header, the
    /// info screen and the forward picker would otherwise each have to remember, and the one that
    /// forgot would be the screen where a friend's real name suddenly reappeared.
    ///
    /// Personal chats only. A group's name is shared with everybody in it, and showing one member
    /// a private version of it is how two people end up unable to talk about the same room.
    func title(besides ownUserID: String?) -> String {
        if kind == .direct, let local = LocalNames.name(for: id) { return local }
        return serverTitle(besides: ownUserID)
    }

    /// The name the *server* would give it, with no nickname over the top.
    ///
    /// Kept apart from `title` for the screens that have to survive a rename happening while they
    /// are open: a nickname is set on this device and no sync follows it, so nothing will hand
    /// them a fresh `RoomInfo` to recompute from. They hold this instead, and put the nickname
    /// back on it when one arrives. See `TimelineStore.adopt`.
    func serverTitle(besides ownUserID: String?) -> String {
        displayName
            ?? counterpart(besides: ownUserID)?.displayName
            ?? heroes.first?.displayName
            ?? String(core: CoreStrings.Room.untitled)
    }

    /// The picture to show for the room.
    ///
    /// In a personal chat this falls back to the other person's, and it has to: a one-to-one
    /// room almost never carries an avatar of its own, and the picture a person expects beside
    /// a conversation with Аня is Аня's. The name has always fallen back this way — the picture
    /// did not, which is why personal chats showed a name beside a circle of initials while the
    /// face was sitting in the same `RoomInfo` all along.
    ///
    /// In a group it must *not* fall back. A hero is one member, picked by the server to
    /// describe the room; putting their photograph up as the room's own would label a group
    /// with the face of whoever happened to be listed first.
    func pictureURL(besides ownUserID: String?) -> String? {
        if let avatarUrl, !avatarUrl.isEmpty { return avatarUrl }
        guard kind == .direct else { return nil }
        return counterpart(besides: ownUserID)?.avatarUrl
    }
}
