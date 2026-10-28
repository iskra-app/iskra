import Foundation

/// One push, decrypted, in the words a person will actually read.
///
/// A Matrix push carries no message. It carries a room ID and an event ID, and every
/// word on the lock screen has to be fetched and decrypted on the device that receives
/// it — the homeserver could not write the sentence even if it wanted to, because in an
/// encrypted room it cannot read the message either. That is the whole reason the
/// notification extension exists, and this is what it gets for its trouble.
///
/// Plain values, already localized, with nothing of the SDK left in them: the thing that
/// renders this lives in another process and another target, and `IskraCore` does not
/// hand an SDK type to anybody.
public struct PushNotification: Sendable, Equatable {
    public let roomID: String
    public let eventID: String

    /// The line at the top: the room's name — except in a one-to-one chat, where the room
    /// *is* the person and its name is already theirs.
    public let title: String

    /// Who spoke, when the title is a room with people in it. Nil in a direct chat, where
    /// printing the name a second time is the only thing it would achieve.
    public let sender: String?

    public let body: String

    /// Whether the user's own push rules asked for this one to make a sound. Read from the
    /// rules rather than decided here: a muted room is muted because the user said so, and
    /// this is where that instruction arrives.
    public let isNoisy: Bool

    /// Who spoke, as a name, *always* — including in a direct chat, where `sender` is
    /// deliberately nil because printing the name twice is all it would achieve.
    ///
    /// The two are not the same question. `sender` is "what goes on the second line"; this is
    /// "whose message is this", and a notification that draws a person needs an answer even when
    /// it has nowhere to write it. Nil only when the sender chose no display name and their
    /// Matrix ID is all there is.
    public let personName: String?

    /// The sender's Matrix ID. What tells iOS that twenty messages from one person are twenty
    /// messages from *one person*: it is the handle the intent is built around, and it is stable
    /// in a way a display name is not.
    public let personID: String?

    /// The sender's avatar, as an `mxc://` URL — not bytes. The mapper is a pure function and
    /// cannot fetch anything; `PushDecoder` is what turns this into `avatar`.
    public let avatarURL: String?

    /// The avatar, downloaded and decrypted. Nil whenever it could not be had in time, which is
    /// not a failure: a notification without a picture is a notification, and a notification that
    /// arrived late because it waited for a picture is not.
    public let avatar: Data?

    /// A room with people in it, rather than a chat with one person: then the notification comes
    /// *from the room* — its name on top, its picture in the circle — and who spoke is written into
    /// the text, "Аня: …". Decided by the mapper, from the room, not from whether there happens to
    /// be a name for a second line (`sender`), which is what used to make a group arrive looking
    /// like a personal message whenever its sender had no display name.
    public let isGroup: Bool

    /// The room's picture, for a group — an `mxc://` URL, fetched by `PushDecoder` into
    /// `roomAvatar`, as `avatarURL` is into `avatar`.
    public let roomAvatarURL: String?
    public let roomAvatar: Data?

    public init(roomID: String,
                eventID: String,
                title: String,
                sender: String?,
                body: String,
                isNoisy: Bool,
                personName: String? = nil,
                personID: String? = nil,
                avatarURL: String? = nil,
                avatar: Data? = nil,
                isGroup: Bool = false,
                roomAvatarURL: String? = nil,
                roomAvatar: Data? = nil) {
        self.roomID = roomID
        self.eventID = eventID
        self.title = title
        self.sender = sender
        self.body = body
        self.isNoisy = isNoisy
        self.personName = personName
        self.personID = personID
        self.avatarURL = avatarURL
        self.avatar = avatar
        self.isGroup = isGroup
        self.roomAvatarURL = roomAvatarURL
        self.roomAvatar = roomAvatar
    }

    /// The same notification with its picture in it. Written this way so that the fetch lives in
    /// `PushDecoder`, where the client is, and the mapper stays a pure function of an SDK value.
    public func withAvatar(_ avatar: Data?) -> PushNotification {
        PushNotification(roomID: roomID, eventID: eventID, title: title, sender: sender, body: body,
                         isNoisy: isNoisy, personName: personName, personID: personID,
                         avatarURL: avatarURL, avatar: avatar,
                         isGroup: isGroup, roomAvatarURL: roomAvatarURL, roomAvatar: roomAvatar)
    }

    /// The same notification with the room's picture in it — see `withAvatar`.
    public func withRoomAvatar(_ roomAvatar: Data?) -> PushNotification {
        PushNotification(roomID: roomID, eventID: eventID, title: title, sender: sender, body: body,
                         isNoisy: isNoisy, personName: personName, personID: personID,
                         avatarURL: avatarURL, avatar: avatar,
                         isGroup: isGroup, roomAvatarURL: roomAvatarURL, roomAvatar: roomAvatar)
    }

    /// The same notification under another title — the account's name added to it.
    public func titled(_ title: String) -> PushNotification {
        PushNotification(roomID: roomID, eventID: eventID, title: title, sender: sender, body: body,
                         isNoisy: isNoisy, personName: personName, personID: personID,
                         avatarURL: avatarURL, avatar: avatar,
                         isGroup: isGroup, roomAvatarURL: roomAvatarURL, roomAvatar: roomAvatar)
    }
}

/// What to do about a push that has arrived.
///
/// Four answers, and the difference between the last two is the one that matters on a
/// lock screen. A push we *chose* not to show is the system working, and nothing should
/// appear. A push we *could not read* is a failure, and something should appear anyway —
/// the extension leaves the server's own "New message" in place, because a message that
/// arrived silently is worse than a message described badly.
public enum PushOutcome: Sendable, Equatable {
    /// Decrypted, and worth waking someone for.
    case show(PushNotification)

    /// Decrypted, and deliberately not shown.
    case silence(Silence)

    /// Nobody is signed in on this device, so there is no store to open and no keys to
    /// decrypt with. Distinct from `failed` because it is not broken — a push arriving
    /// after a sign-out is an ordinary race, not a fault.
    case notSignedIn

    /// The event could not be reached or read at all.
    case failed(String)

    /// Why a push that decrypted cleanly is still not shown. None of these are errors;
    /// each one is a rule doing its job.
    public enum Silence: Sendable, Equatable {
        /// The user's own push rules said no, or the sender is someone they have ignored.
        /// The room being muted arrives here.
        case filteredOut

        /// Taken back before we got to it. The sender deleted it; showing it now would
        /// defeat the deletion by exactly the margin that matters.
        case redacted

        /// Not something to wake a phone for: a reaction, a call negotiation, a step in a
        /// key-verification handshake. These are events, and they are not news.
        case notWorthWaking
    }
}
