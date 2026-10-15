import Foundation
import MatrixRustSDK

/// How far along a message we sent has got. Only ever shown on our own messages.
public enum DeliveryStatus: Sendable, Equatable {
    case sending
    case sent
    /// Someone else in the room has read it.
    case read
    /// Sending failed, and the SDK said why.
    ///
    /// The reason is carried rather than dropped because "not sent" on its own is a dead
    /// end: it tells the user something is wrong and gives them nothing to do about it.
    /// Most of these failures are things only they can clear — verify a device, accept a
    /// changed identity — so the reason *is* the fix.
    case failed(SendFailure)

    /// Whether this is the failed state, without having to name the reason to ask.
    public var hasFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}

/// Why the send queue is stuck on a message.
///
/// One case per `QueueWedgeError` in the SDK, collapsed to what the user can act on: the
/// SDK distinguishes *which* devices are unverified, but a person reading a chat cannot do
/// anything with a list of device IDs, so the list is dropped and the instruction kept.
///
/// The server's own error text is deliberately not among these. It arrives in English,
/// written for whoever runs the homeserver, and putting it in a bubble would be passing
/// the buck rather than explaining anything.
public enum SendFailure: Sendable, Equatable, CaseIterable {
    /// Someone in the room is signed in on a device nobody has verified.
    case insecureDevices
    /// Someone's identity changed since the last time this device saw them.
    case identityChanged
    /// This device has to be verified before it may send into an encrypted room.
    case verificationRequired
    /// The attachment is gone from local storage — usually deleted between picking it and
    /// the queue getting to it.
    case missingMedia
    case unsupportedFileType
    /// The homeserver refused it.
    case server

    /// One sentence, in the user's language, saying what is wrong and what to do.
    public var explanation: LocalizedStringResource {
        switch self {
        case .insecureDevices: CoreStrings.SendFailure.insecureDevices
        case .identityChanged: CoreStrings.SendFailure.identityChanged
        case .verificationRequired: CoreStrings.SendFailure.verificationRequired
        case .missingMedia: CoreStrings.SendFailure.missingMedia
        case .unsupportedFileType: CoreStrings.SendFailure.unsupportedFileType
        case .server: CoreStrings.SendFailure.server
        }
    }

    /// Whether offering "Send again" is honest.
    ///
    /// Deliberately *not* the SDK's `isRecoverable` flag, which answers a different
    /// question: whether the failure paused the whole room's queue or parked this one
    /// message. A homeserver rejection arrives with `isRecoverable == false` — and sending
    /// it again is precisely the thing that might work, which is why the SDK gives parked
    /// messages a `tryResend` of their own. What decides the button is whether the obstacle
    /// can go away: a file that no longer exists and a file type the server will never take
    /// cannot, an unverified device and a grumpy server can.
    public var canRetry: Bool {
        switch self {
        case .verificationRequired, .server: true
        // Not these two: the send queue stops on them because somebody the user *verified* no
        // longer checks out, and nothing in this app can verify another person again. Sending
        // again would stop on the very same thing. `canSendAnyway` is the way on.
        case .insecureDevices, .identityChanged: false
        case .missingMedia, .unsupportedFileType: false
        }
    }

    /// Whether the user can decide to send it regardless — see `TimelineStore.sendAnyway`.
    ///
    /// A decision about trust, which is why it is theirs to make and never made for them: it
    /// withdraws the verification that no longer holds, or trusts the device that nobody
    /// confirmed, for this person, from now on.
    public var canSendAnyway: Bool {
        switch self {
        case .insecureDevices, .identityChanged: true
        case .verificationRequired, .server, .missingMedia, .unsupportedFileType: false
        }
    }
}

/// What a message actually is. The UI switches on this to pick a bubble.
public enum MessageKind: Sendable, Equatable {
    case text(String)
    case emote(String)
    case notice(String)
    case image(Attachment)
    /// A sticker. A picture in Matrix's vocabulary and a different thing in a conversation:
    /// it is not an *attachment* somebody sent, it is a thing they said. Its own case, because
    /// the difference is the whole of how it is drawn — no bubble, no caption, nothing to open.
    case sticker(Attachment)
    case video(Attachment)
    /// A round video message, recorded in the chat. See `VideoNote`.
    case videoNote(Attachment)
    case voice(Attachment, waveform: [Float])
    case audio(Attachment)
    case file(Attachment)
    case location(Location)
    /// A question with answers to choose from, and the room's tally so far. See `Poll`.
    case poll(Poll)
    /// The message is there, but this device was never given the key to read it.
    case unreadable
    case deleted
    /// Something we do not render yet. Better an honest blank than a wrong guess.
    case unsupported
}

public extension Attachment {
    /// A picture known only by its `mxc://` URL — a person's or a room's avatar, opened full screen
    /// from their page. Nil for a URL the SDK will not read as one.
    static func picture(url: String) -> Attachment? {
        guard let source = try? MediaSource.fromUrl(url: url) else { return nil }
        return Attachment(source: source,
                          thumbnailSource: nil,
                          filename: "avatar.jpg",
                          caption: nil,
                          width: nil,
                          height: nil,
                          duration: nil,
                          mimeType: nil,
                          blurhash: nil)
    }
}

/// A downloadable piece of media. The bytes are fetched lazily via `MediaLoader`,
/// because a timeline of a hundred photos should not pull a hundred photos.
public struct Attachment: Sendable, Equatable {
    /// Where the bytes are, in the SDK's terms.
    ///
    /// Internal, not public, and the compiler now says so. `MediaSource` is a `MatrixRustSDK` type,
    /// and this was the one place an SDK type reached the public surface of `IskraCore` — the rule
    /// that the SDK does not leave this target was being kept by discipline rather than by anything
    /// that would stop you. Nothing above ever read it (`MediaLoader`, in here, is the only caller),
    /// so nothing had to change but the word.
    let source: MediaSource
    /// The still the *sender* uploaded alongside the file, when they uploaded one.
    ///
    /// This is the only way a video ever gets a picture in an encrypted room. Asking the
    /// server to thumbnail the file itself — which is what `getMediaThumbnail` does — cannot
    /// work there: what the server holds is ciphertext, and it has no key and no video
    /// decoder to point at it. It answers with an error and the bubble stays grey.
    let thumbnailSource: MediaSource?
    public let filename: String
    public let caption: String?
    public let width: Int?
    public let height: Int?
    public let duration: TimeInterval?
    /// What the sender said the bytes are — "video/mp4". Needed to *play* them: the SDK
    /// writes the decrypted file to disk and has to be told what to call it, and `AVPlayer`
    /// reads the type from the extension. A sender who omitted it leaves this nil, and
    /// `MediaLoader` falls back to guessing from the filename.
    public let mimeType: String?
    /// A tiny blurred placeholder the sender computed for us, so the bubble can have
    /// something to show immediately instead of a grey box.
    public let blurhash: String?

    /// The same shape test the timeline uses to decide a message is a circle — see
    /// `VideoNote`. It is asked again here because `MediaLoader` is handed an attachment,
    /// not a message, and what it may do to get a picture depends on how big the file
    /// behind it can be.
    public var isVideoNote: Bool {
        guard let width, let height, let duration else { return false }
        return width == height && width > 0 && duration <= VideoNote.maximumDuration
    }

    /// What identifies the bytes behind this attachment: the `mxc://` URL the room event
    /// points at.
    ///
    /// A view needs one to key a fetch on, and `filename` is not it — every sticker in the
    /// app is called "sticker", so a view that keyed on the name would go on showing the
    /// picture it fetched for the last one.
    public var mediaID: String { source.url() }

    public var aspectRatio: Double? {
        guard let width, let height, height > 0 else { return nil }
        return Double(width) / Double(height)
    }

    public static func == (lhs: Attachment, rhs: Attachment) -> Bool {
        lhs.filename == rhs.filename
            && lhs.caption == rhs.caption
            && lhs.width == rhs.width
            && lhs.height == rhs.height
            && lhs.duration == rhs.duration
            && lhs.blurhash == rhs.blurhash
            && lhs.source.url() == rhs.source.url()
    }
}

/// One emoji under a message, and how many people have pressed it.
///
/// `isMine` is not decoration: a reaction is a toggle, and pressing one you already left
/// takes it away again. The pill has to be able to say which of the two is about to
/// happen *before* it is pressed, so whether we are among the senders is carried here
/// rather than worked out again in the view.
public struct MessageReaction: Sendable, Identifiable, Equatable {
    /// The emoji itself — "👍". Matrix calls this the reaction's key, and it is one.
    public let key: String
    public let count: Int
    public let isMine: Bool
    /// Who left it, by Matrix ID, earliest first — for "who reacted" in a group's message menu.
    /// IDs only: names are the room's to give, and are asked for when somebody opens the list
    /// (`TimelineStore.reactors(of:)`), not for every pill in every row.
    public let senders: [String]

    public init(key: String, count: Int, isMine: Bool, senders: [String] = []) {
        self.key = key
        self.count = count
        self.isMine = isMine
        self.senders = senders
    }

    public var id: String { key }
}

/// One person's reaction, named — a line in the "who reacted" list.
public struct Reactor: Sendable, Identifiable, Equatable {
    public let key: String
    public let userID: String
    public let name: String
    public let avatarURL: String?

    public var id: String { key + "|" + userID }

    public init(key: String, userID: String, name: String, avatarURL: String?) {
        self.key = key
        self.userID = userID
        self.name = name
        self.avatarURL = avatarURL
    }
}

/// The message a reply is answering, boiled down to what fits in a strip.
///
/// A *copy*, not a pointer. The original may be a thousand messages up the conversation and
/// not loaded at all, so what the quote shows has to travel with the reply — which is exactly
/// what Matrix does: the SDK resolves `inReplyTo` for us and hands back the sender and the
/// content, or says it could not.
///
/// `eventID` survives even when the rest does not, because it is the one thing a quote is
/// *for*: pressing it goes to the message being answered, and that works whether or not we
/// managed to summarise it.
public struct ReplyPreview: Sendable, Equatable {
    public let eventID: String
    /// Nil while the SDK is still fetching the original, or where it never found it. Settable
    /// inside the core, so a nickname can stand in for it — see `TimelineStore.applyingLocalName`.
    public internal(set) var senderName: String?
    /// Who wrote the original, when the SDK has said — what a nickname is matched against.
    public let senderID: String?
    /// One line, already summarised — "Photo", "Voice message", or the words themselves.
    public let text: String

    public init(eventID: String, senderName: String?, senderID: String? = nil, text: String) {
        self.eventID = eventID
        self.senderName = senderName
        self.senderID = senderID
        self.text = text
    }
}

/// One message, flattened into something SwiftUI can diff.
public struct Message: Sendable, Identifiable, Equatable {
    public let id: String
    public let kind: MessageKind
    public let senderID: String
    /// Settable inside the core, so a nickname can stand in for it — see
    /// `TimelineStore.applyingLocalName`.
    public internal(set) var senderName: String
    public let senderAvatarURL: String?
    public let isOwn: Bool
    public let timestamp: Date
    /// Not `let`: a read receipt points at one event, and `TimelineMapper.withReadPropagated`
    /// carries "read" back down the messages under it.
    public var delivery: DeliveryStatus?
    /// When somebody else first read it, for one of your own that has been read.
    ///
    /// The earliest read receipt on the event, and "earliest" is the decision: in a room of
    /// twenty people the receipts go on arriving for hours, and the question anybody presses a
    /// message to ask is when it *was read*, not when the last person got round to it.
    ///
    /// Nil far more often than `delivery == .read` is false, and that is not a bug to be tidied
    /// away: a receipt is allowed to arrive without a timestamp on it — the SDK says so — and a
    /// homeserver that sends one is telling us the message was read and not when. So the menu
    /// shows the line when there is a moment to show and says nothing when there is not, rather
    /// than inventing one from the clock.
    ///
    /// Not `let`, for the same reason `delivery` is not: the moment the reader caught up lives on
    /// the event *they* last read, which is usually not one of yours — `TimelineMapper` hands it
    /// down to every message of yours that receipt covers. On the message the receipt names it is
    /// the moment it was read; above, it is the moment by which it had been. That is the whole of
    /// what a receipt knows, and it is the same sentence either way: "read at 14:03" is not a claim
    /// about the second, it is the reader saying so.
    public var readAt: Date?
    public let isEdited: Bool
    /// What this message is an answer to, for one that is.
    public internal(set) var replyTo: ReplyPreview?
    /// In the order they were first left, so a busy message does not reshuffle its own
    /// emoji every time someone adds one.
    public let reactions: [MessageReaction]
    /// When the message was taken back, for one that has been. Nil for every message that
    /// is still there — and nil, too, for a redaction the homeserver did not date: see
    /// `TimelineMapper.redaction`.
    public let deletedAt: Date?
    /// The Matrix IDs this message says it mentions — the event's `m.mentions` set. Used to light
    /// up a name in the text (and to know when that name is *yours*), which is why it travels as
    /// plain IDs rather than as pre-rendered markup: the bubble does the painting, from this.
    public let mentionedUserIDs: [String]
    /// The message's HTML, for a text, emote or notice that carries some — bold, links, lists,
    /// quotes. Kept as the sender wrote it and drawn by `MatrixHTML` in the bubble, for the same
    /// reason the plain body is kept as a `String`: cheap to diff, and nothing in the model layer
    /// holds an `AttributedString`. Nil for a plain message, which is drawn from `kind` as ever.
    public var formattedBody: String?
    /// Where it was forwarded from, for a message that says it was — see `ForwardOrigin`.
    public var forwardedFrom: ForwardOrigin?
    /// Grouped under one avatar with the message above it, iMessage-style.
    public var isContinuation: Bool = false
    /// And the other end of the same fact: the message *below* this one is a continuation of it.
    ///
    /// The bubbles put the face beside the last message of a run, at its foot, the way Telegram
    /// does — where the run ends is where the eye arrives — so the row has to know it is not the
    /// last. A row cannot work that out from itself, and the screen should not be asked to look
    /// at its neighbours, so it is set over the finished rows by `TimelineMapper.markRunEnds`.
    /// The compact layout keeps its face at the top and does not read this.
    public var isContinued: Bool = false
    /// The one message that wears the "read" mark on behalf of all of them.
    ///
    /// A receipt is monotonic, so every message of yours above the watermark is equally read, and
    /// putting an eye on each one said the same true thing fifteen times down the side of the
    /// screen. One mark says it once, and above it the margin goes quiet altogether: a checkmark
    /// means a message is out and nobody has read it yet, the eye means the reader got this far,
    /// and nothing at all means there is nothing outstanding to say. `delivery` still reads
    /// `.read` on every one of them for anything that asks — what stops is the drawing, not the
    /// fact.
    ///
    /// The newest *read* message rather than simply the newest: a message still in flight below it
    /// would otherwise take the mark off a conversation that has plainly been read.
    public var carriesReadMark: Bool = false

    /// How much of an attachment has gone up, from 0 to 1, while it is still going up.
    ///
    /// Nil for everything that is not an upload in progress — every text, every message of
    /// somebody else's, every attachment that has finished. The SDK reports it on the local echo
    /// (`EventSendState.notSentYet(progress:)`), and the bubble draws it as a ring over the picture
    /// with a cross in it, the way Telegram does: a photo that sits with a clock beside it for a
    /// minute on a slow network looks exactly like a photo that is stuck, and a ring that moves is
    /// the difference.
    public var uploadProgress: Double?

    /// The pictures this row stands for, when it is an album — the first of them is this message.
    /// Nil for every ordinary message. See `Album`.
    public var album: [Message]?

    public init(id: String,
                kind: MessageKind,
                senderID: String,
                senderName: String,
                senderAvatarURL: String?,
                isOwn: Bool,
                timestamp: Date,
                delivery: DeliveryStatus?,
                readAt: Date? = nil,
                isEdited: Bool,
                replyTo: ReplyPreview? = nil,
                reactions: [MessageReaction],
                deletedAt: Date? = nil,
                mentionedUserIDs: [String] = [],
                formattedBody: String? = nil,
                forwardedFrom: ForwardOrigin? = nil,
                isContinuation: Bool = false,
                carriesReadMark: Bool = false,
                uploadProgress: Double? = nil) {
        self.id = id
        self.kind = kind
        self.senderID = senderID
        self.senderName = senderName
        self.senderAvatarURL = senderAvatarURL
        self.isOwn = isOwn
        self.timestamp = timestamp
        self.delivery = delivery
        self.readAt = readAt
        self.isEdited = isEdited
        self.replyTo = replyTo
        self.reactions = reactions
        self.deletedAt = deletedAt
        self.mentionedUserIDs = mentionedUserIDs
        self.formattedBody = formattedBody
        self.forwardedFrom = forwardedFrom
        self.isContinuation = isContinuation
        self.carriesReadMark = carriesReadMark
        self.uploadProgress = uploadProgress
    }

    /// Whether the message has been taken back.
    public var isDeleted: Bool {
        if case .deleted = kind { return true }
        return false
    }

    /// Whether an emoji may be left on this message.
    ///
    /// Not on one that is gone. Matrix will happily accept the reaction — it is an event
    /// pointing at an event, and the server does not care that the target is a tombstone —
    /// and the whole room is then left looking at a 👍 hanging under the words "message
    /// deleted". Nor on a message that has not been sent yet: a reaction refers to an event
    /// ID, and a message still in the send queue does not have one.
    public var canReact: Bool {
        guard !isDeleted else { return false }
        guard let delivery else { return true }  // Someone else's, and therefore on the server.
        return delivery == .sent || delivery == .read
    }

    /// Whether this message can be forwarded into another room.
    ///
    /// Anyone's, not only your own — forwarding is quoting, not editing. The kinds are the ones a
    /// forward can faithfully rebuild: words, and the three attachments whose bytes can be fetched
    /// and re-sent through the encrypting path. A voice note, a video note, a location or a sticker
    /// would each need its own metadata re-derived, and nobody forwards those — so they cannot.
    public var canForward: Bool {
        guard !isDeleted else { return false }
        switch kind {
        case .text, .notice, .emote, .image, .video, .file: return true
        default: return false
        }
    }

    /// Whether the user is allowed to take this message back.
    ///
    /// Only their own, and only one that actually reached the server: a message still
    /// sitting in the send queue has no event to redact, and a failed one is undone by
    /// the red badge beside it, not by a menu item that would quietly do nothing.
    public var canDelete: Bool {
        guard isOwn, !isDeleted else { return false }
        return delivery == .sent || delivery == .read
    }

    /// Whether somebody who may delete other people's messages may delete this one: anybody else's,
    /// as long as there is still something there. One's own go by `canDelete`.
    public var canBeDeletedByModerator: Bool {
        !isOwn && !isDeleted
    }

    /// Whether the user may close this poll: their own, still open, and on the server.
    public var canEndPoll: Bool {
        guard case let .poll(poll) = kind, isOwn, !poll.isEnded else { return false }
        return delivery == .sent || delivery == .read
    }

    /// Whether the user may go back and change what they wrote.
    ///
    /// Only their own words: text, notices and emotes — and the caption under their own photo,
    /// video or file, which is words too, and which can be added to one sent without any
    /// (`hasCaption`). A sticker, a circle and a voice message have nothing to write under them.
    ///
    /// And only a message the server has: an edit is an event pointing at an event, and one
    /// still in the send queue has no event to point at. A message that has not gone yet is
    /// fixed by discarding it and writing it again, which is what the red badge already offers.
    public var canEdit: Bool {
        guard isOwn, !isDeleted, editingText != nil else { return false }
        return delivery == .sent || delivery == .read
    }

    /// Whether what this message is can carry a caption: a photo, a video, a piece of music or a
    /// file. Not a sticker, a circle or a voice message, which are the whole of what they say.
    public var hasCaption: Bool {
        captioned != nil
    }

    /// The attachment under which a caption goes, for the kinds that take one.
    public var captioned: Attachment? {
        switch kind {
        case let .image(attachment), let .video(attachment), let .audio(attachment), let .file(attachment):
            attachment
        default:
            nil
        }
    }

    /// What the composer is filled with when an edit begins: the words of a message, or the
    /// caption of an attachment — empty when it has none yet, so that "Edit" on a photo is how a
    /// caption is added afterwards.
    public var editingText: String? {
        editableText ?? captioned.map { $0.caption ?? "" }
    }

    /// What the composer is filled with when an edit begins — the message as it now stands.
    public var editableText: String? {
        switch kind {
        case let .text(body): body
        case let .notice(body): body
        case let .emote(body): body
        default: nil
        }
    }

    /// Whether this message may be answered.
    ///
    /// Same rule as a reaction, and for the same reason: a reply names an event, and a message
    /// still in the send queue does not have one. Answering a message that has been taken back
    /// is allowed — the quote will read "message deleted", which is the truth, and people do
    /// reply to the fact that something was withdrawn.
    public var canReply: Bool {
        guard !isDeleted else { return false }
        guard let delivery else { return true }
        return delivery == .sent || delivery == .read
    }
}

/// Something that happened in the room that nobody said.
///
/// People arriving and leaving, the room being renamed, the day encryption was turned on. The
/// SDK reports these as timeline items exactly like messages, and this app used to drop every
/// one of them on the floor — so a room you had just been added to opened on a conversation
/// that began in the middle of nowhere.
///
/// They are *facts*, not messages: no sender, no bubble, no reactions, one grey line across
/// the middle of the conversation. And they are pooled — five people joining a room is one
/// line, not five, which is the difference between a note in the margin and a wall of noise.
public struct RoomEvent: Sendable, Identifiable, Equatable {
    public let id: String
    public let kind: RoomEventKind
    public let timestamp: Date
    /// Who did it, where the line names them by something other than a member list — a person
    /// renaming themselves. See `people`.
    public let actorID: String?

    public init(id: String, kind: RoomEventKind, timestamp: Date, actorID: String? = nil) {
        self.id = id
        self.kind = kind
        self.timestamp = timestamp
        self.actorID = actorID
    }

    /// The people this line names, each with the Matrix ID behind the name — what makes a name in
    /// the grey line something to press, the way Telegram's are: "Аня joined" goes to Аня.
    public var people: [RoomEventPerson] {
        if let people = kind.people { return people }
        if case let .renamedThemselves(_, to) = kind, let actorID {
            return [RoomEventPerson(userID: actorID, name: to)]
        }
        return []
    }

    /// The line, in the reader's language.
    ///
    /// Composed here rather than in the view, because it is text the model layer produces and
    /// that is where such text lives (`CoreStrings`). The view is handed a sentence and draws
    /// it grey; it does not know that five people joining and one person joining are the same
    /// event with a different list in it.
    public var text: String {
        switch kind {
        case let .joined(names): String(core: CoreStrings.RoomEvent.joined(Self.list(names)))
        case let .left(names): String(core: CoreStrings.RoomEvent.left(Self.list(names)))
        case let .invited(names): String(core: CoreStrings.RoomEvent.invited(Self.list(names)))
        case let .removed(names): String(core: CoreStrings.RoomEvent.removed(Self.list(names)))
        case let .banned(names): String(core: CoreStrings.RoomEvent.banned(Self.list(names)))
        case let .renamedThemselves(from, to):
            String(core: CoreStrings.RoomEvent.renamedThemselves(from: from, to: to))
        case let .roomRenamed(name): String(core: CoreStrings.RoomEvent.roomRenamed(name))
        case .roomTopicChanged: String(core: CoreStrings.RoomEvent.roomTopicChanged)
        case .roomPictureChanged: String(core: CoreStrings.RoomEvent.roomPictureChanged)
        case .roomCreated: String(core: CoreStrings.RoomEvent.roomCreated)
        case .encryptionEnabled: String(core: CoreStrings.RoomEvent.encryptionEnabled)
        }
    }

    /// People, named as far as it is worth naming them.
    ///
    /// One is a name. Two are both named — a room where two people join at once is a room where
    /// you want to know who they both were. Three or more become the first name and a count,
    /// because a grey line listing eleven people is not a line, it is a paragraph, and nobody
    /// reads it.
    private static func list(_ people: [RoomEventPerson]) -> String {
        let names = people.map(\.name)
        return switch names.count {
        case 0: ""
        case 1: names[0]
        case 2: String(core: CoreStrings.RoomEvent.pair(names[0], names[1]))
        default: String(core: CoreStrings.RoomEvent.others(names[0], names.count - 1))
        }
    }
}

/// One person named in a room event: the name the line says, and the Matrix ID it stands for.
///
/// A string literal makes one whose ID *is* the name, which is what a test that only cares about the
/// sentence wants to write.
public struct RoomEventPerson: Sendable, Hashable, ExpressibleByStringLiteral {
    public let userID: String
    public let name: String

    public init(userID: String, name: String) {
        self.userID = userID
        self.name = name
    }

    public init(stringLiteral value: String) {
        self.init(userID: value, name: value)
    }
}

/// What a room event says, in a vocabulary the UI can turn into a sentence.
///
/// A *structure* rather than a finished string, and it has to be: two consecutive joins are
/// collapsed into one line, and collapsing sentences is not something you can do to sentences.
/// See `RoomEventKind.merged(with:)`.
public enum RoomEventKind: Sendable, Equatable {
    /// Somebody, or several somebodies, arrived. Each is named by their display name where the
    /// room knew one and their Matrix ID where it did not — and carries the ID either way.
    case joined([RoomEventPerson])
    case left([RoomEventPerson])
    case invited([RoomEventPerson])
    case removed([RoomEventPerson])
    case banned([RoomEventPerson])

    /// Somebody changed the name they go by.
    case renamedThemselves(from: String, to: String)

    /// The room itself changed.
    case roomRenamed(String)
    case roomTopicChanged
    case roomPictureChanged
    case roomCreated
    case encryptionEnabled

    /// The people named, for the shapes that name people. Nil for the rest, which is what
    /// lets `merged(with:)` refuse to pool two lines that have nobody to pool.
    public var people: [RoomEventPerson]? {
        switch self {
        case let .joined(names), let .left(names), let .invited(names),
             let .removed(names), let .banned(names):
            names
        default:
            nil
        }
    }

    /// The same event, with more people in it. Nil where the two do not belong on one line.
    ///
    /// Only ever merges like with like: "Аня вошла" and "Борис вышел" are two different facts
    /// and pooling them would produce a sentence that is not true of either. A name already in
    /// the list is not added twice — somebody who leaves and rejoins in the same minute should
    /// not appear in the line as two people.
    public func merged(with other: RoomEventKind) -> RoomEventKind? {
        guard let mine = people, let theirs = other.people else { return nil }

        // The same *person*, by ID: two people who both call themselves Аня are two people.
        let combined = mine + theirs.filter { person in !mine.contains { $0.userID == person.userID } }

        switch (self, other) {
        case (.joined, .joined): return .joined(combined)
        case (.left, .left): return .left(combined)
        case (.invited, .invited): return .invited(combined)
        case (.removed, .removed): return .removed(combined)
        case (.banned, .banned): return .banned(combined)
        default: return nil
        }
    }
}

/// A day separator between messages.
public struct DayDivider: Sendable, Identifiable, Equatable {
    public let id: String
    public let date: Date
}

/// A message, the date header above it, or a note about something that happened.
public enum TimelineRow: Sendable, Identifiable, Equatable {
    case message(Message)
    case dayDivider(DayDivider)
    case event(RoomEvent)
    /// "Unread messages": where the reader left off last time, and everything under it is new.
    ///
    /// The SDK's read marker — the account's `m.fully_read` — drawn the way Telegram draws it, as a
    /// bar across the conversation. It is what a room opens on when there is more new below it than
    /// fits on a screen, so the reader starts at the first thing they have not seen rather than at
    /// the last thing anybody said. See `RoomView` and `TimelineStore.markAsRead`, which is careful
    /// about *when* the marker moves.
    case unreadDivider

    /// The one identity the bar ever has. There is at most one read marker in a timeline.
    public static let unreadDividerID = "unread-divider"

    public var id: String {
        switch self {
        case let .message(message): message.id
        case let .dayDivider(divider): divider.id
        case let .event(event): event.id
        case .unreadDivider: Self.unreadDividerID
        }
    }

    /// A bar across the conversation — a date, or where the unread begins. Both give the row under
    /// them its air, so that row does not pay for its own on top.
    public var isDivider: Bool {
        switch self {
        case .dayDivider, .unreadDivider: true
        case .message, .event: false
        }
    }

    /// The message this row is, for the many places that only care about those.
    public var message: Message? {
        guard case let .message(message) = self else { return nil }
        return message
    }
}
