import Testing
import Foundation
import MatrixRustSDK
@testable import IskraCore

/// What a push says by the time it reaches a lock screen.
///
/// `PushDecoder` itself cannot be tested here — it opens an encrypted store, restores a
/// session and reaches the network, and a `swift test` binary is unsigned and has none of
/// those. `PushMapper` is the half that decides every *word*, and it is a pure function of
/// an SDK value, so all of it is pinned below. The other half is answered on a device, by
/// `Iskra --probe-notification`.
struct PushTests {
    // MARK: - Building the SDK's values

    private static func room(named name: String, isDm: Bool = false) -> NotificationRoomInfo {
        NotificationRoomInfo(displayName: name,
                             avatarUrl: nil,
                             canonicalAlias: nil,
                             topic: nil,
                             joinRule: nil,
                             joinedMembersCount: 2,
                             activeServiceMembersCount: 0,
                             serviceMembers: [],
                             isEncrypted: true,
                             isDirect: isDm,
                             isSpace: false,
                             isDm: isDm)
    }

    private static func sender(named name: String?) -> NotificationSenderInfo {
        NotificationSenderInfo(displayName: name, avatarUrl: nil, isNameAmbiguous: false)
    }

    private static func item(_ event: NotificationEvent,
                             room: NotificationRoomInfo,
                             sender: NotificationSenderInfo,
                             isNoisy: Bool = false) -> NotificationItem {
        NotificationItem(event: event,
                         rawEvent: "{}",
                         senderInfo: sender,
                         roomInfo: room,
                         isNoisy: isNoisy,
                         hasMention: false,
                         threadId: nil,
                         actions: nil)
    }

    // MARK: - Who it is from

    /// The rule that decides the two lines at the top. In a group both are needed; in a
    /// one-to-one chat the room's name already *is* the person's, and printing it twice —
    /// once as the title and once again directly beneath — is the failure this prevents.
    @Test("a direct chat is titled with the person, and does not name them twice")
    func directChatNamesThePersonOnce() {
        let direct = PushMapper.attribution(roomName: "Аня", senderName: "Аня", isDirect: true)
        #expect(direct.title == "Аня")
        #expect(direct.sender == nil)

        let group = PushMapper.attribution(roomName: "Кухня", senderName: "Аня", isDirect: false)
        #expect(group.title == "Кухня")
        #expect(group.sender == "Аня")
    }

    /// A sender with no display name must not produce a blank second line — the room carries
    /// the notification on its own.
    @Test("a nameless sender leaves the room to speak for itself")
    func namelessSenderDoesNotLeaveABlankLine() {
        let group = PushMapper.attribution(roomName: "Кухня", senderName: "", isDirect: false)
        #expect(group.title == "Кухня")
        #expect(group.sender == nil)
    }

    /// Found by running the thing, not by thinking about it. The matrix.org welcome room —
    /// which *every* new account is given — is not flagged `isDm`, and its display name is
    /// precisely the name of the account that posts in it. Keying the rule off `isDm` alone
    /// therefore produced a notification headed "Matrix.org (Official Account)" with
    /// "Matrix.org (Official Account)" written directly underneath it, on the first real
    /// message `Iskra --probe-notification` ever decrypted.
    ///
    /// So this is the invariant, and it is the one a person can actually see: whatever the
    /// room thinks it is, the same name never appears twice.
    @Test("a room named after the person in it does not say their name twice")
    func aRoomNamedAfterItsSenderSaysTheNameOnce() {
        let welcome = PushMapper.attribution(roomName: "Matrix.org (Official Account)",
                                             senderName: "Matrix.org (Official Account)",
                                             isDirect: false)
        #expect(welcome.title == "Matrix.org (Official Account)")
        #expect(welcome.sender == nil)
    }

    // MARK: - The words

    /// The point of sharing `MessagePreview` between the chat list and the push: a photo is
    /// "Фото" in both places, because it is one sentence written once. Two independent
    /// switches over `MessageType` would drift, and the drift would show up as a lock screen
    /// that disagrees with the app behind it.
    @Test("an attachment is described in the same words as in the chat list")
    func attachmentsBorrowTheChatListsWords() throws {
        let photo = MessageType.image(content: ImageMessageContent(
            filename: "cat.jpg",
            caption: nil,
            formattedCaption: nil,
            source: try MediaSource.fromUrl(url: "mxc://example.org/cat"),
            info: nil))

        // Compared against the chat list's own string rather than against a fixed word, and in
        // whatever locale the test happens to run in. That is the invariant worth holding: not
        // that a photo is called "Фото", but that it is called *the same thing in both places*.
        #expect(MessagePreview.text(for: photo) == String(core: CoreStrings.Preview.photo))
    }

    /// The user's own words are never a string to translate — they are passed through exactly
    /// as written, which is the one thing a notification must never paraphrase.
    @Test("a text message arrives as itself")
    func textIsPassedThroughUntouched() {
        let message = MessageType.text(content: TextMessageContent(body: "жду на кухне", formatted: nil))
        #expect(MessagePreview.text(for: message) == "жду на кухне")
    }

    /// A reaction is an event and it is not news. Nothing here should wake a phone for one —
    /// and the push rules usually strip them long before this, which is exactly why the case
    /// is easy to leave out and never notice.
    @Test("a reaction is not something to wake a phone for")
    func reactionsAreNotNews() {
        #expect(PushMapper.text(for: .reactionContent(relatedEventId: "$1")) == nil)
        #expect(PushMapper.text(for: .callCandidates) == nil)
        #expect(PushMapper.text(for: .keyVerificationDone) == nil)
    }

    /// A message whose key never arrived still says *something*. Silence would be the worse
    /// answer: a message was sent, the user is entitled to know that much, and "cannot be
    /// read" is the honest way to say it.
    @Test("a message we cannot decrypt still announces itself")
    func anUnreadableMessageStillSaysSo() {
        #expect(PushMapper.text(for: .roomEncrypted) == String(core: CoreStrings.Preview.unreadable))
        #expect(PushMapper.text(for: .roomEncrypted)?.isEmpty == false)
    }

    // MARK: - Invitations

    @Test("an invitation reads as a sentence, in both languages")
    func invitationsAreASentence() {
        let invite = Self.item(.invite(sender: "@anya:matrix.org"),
                               room: Self.room(named: "Кухня"),
                               sender: Self.sender(named: "Аня"))

        guard case let .show(notification) = PushMapper.outcome(for: invite,
                                                                roomID: "!room:matrix.org",
                                                                eventID: "$event") else {
            Issue.record("an invitation should be shown")
            return
        }

        #expect(notification.title == "Кухня")
        // The sentence already names them, so the sender line would be the name a second time.
        #expect(notification.sender == nil)
        #expect(notification.body.contains("Аня"))

        // Gender-neutral in Russian, deliberately: Matrix does not know anyone's gender, and
        // "приглашает" is the same word whoever is doing the inviting. "пригласила" would be a
        // coin flip on every name in every room.
        var russian = CoreStrings.Push.invite("Аня")
        russian.locale = Locale(identifier: "ru")
        #expect(String(localized: russian) == "Аня приглашает вас в чат")

        var english = CoreStrings.Push.invite("Аня")
        english.locale = Locale(identifier: "en")
        #expect(String(localized: english) == "Аня invites you to the chat")
    }

    /// Someone who never set a display name is still someone. The Matrix ID is not a name, but
    /// it is what there is, and it beats an invitation from nobody at all.
    @Test("an invitation from someone with no name still names them")
    func anonymousInvitationsFallBackToTheMatrixID() {
        let invite = Self.item(.invite(sender: "@anya:matrix.org"),
                               room: Self.room(named: "Кухня"),
                               sender: Self.sender(named: nil))

        guard case let .show(notification) = PushMapper.outcome(for: invite,
                                                                roomID: "!room:matrix.org",
                                                                eventID: "$event") else {
            Issue.record("an invitation should be shown")
            return
        }
        #expect(notification.body.contains("@anya:matrix.org"))
    }

    /// A room with no name of its own — most Matrix DMs — must not produce a notification
    /// titled with an empty string.
    @Test("a nameless room is still called something")
    func namelessRoomsAreStillTitled() {
        let invite = Self.item(.invite(sender: "@anya:matrix.org"),
                               room: Self.room(named: ""),
                               sender: Self.sender(named: "Аня"))

        guard case let .show(notification) = PushMapper.outcome(for: invite,
                                                                roomID: "!room:matrix.org",
                                                                eventID: "$event") else {
            Issue.record("an invitation should be shown")
            return
        }
        #expect(!notification.title.isEmpty)
        #expect(notification.title == String(core: CoreStrings.Room.untitled))
    }

    // MARK: - What is shown, and what is not

    /// The distinction the whole `PushOutcome` type exists for. A push we *chose* not to show
    /// is the system working — the user muted the room, or the message was taken back. A push
    /// we *could not read* is a failure, and the extension must leave the server's own "New
    /// message" on screen rather than swallow a message that really did arrive.
    @Test("a filtered or redacted push is silenced; one we cannot find is a failure")
    func silenceAndFailureAreDifferentAnswers() {
        #expect(PushMapper.outcome(for: .eventFilteredOut, roomID: "!r", eventID: "$e")
                == .silence(.filteredOut))
        #expect(PushMapper.outcome(for: .eventRedacted, roomID: "!r", eventID: "$e")
                == .silence(.redacted))

        // Not silence — the extension falls back to the server's text on this one.
        guard case .failed = PushMapper.outcome(for: .eventNotFound, roomID: "!r", eventID: "$e") else {
            Issue.record("an event that cannot be found is a failure, not a silence")
            return
        }
    }

    /// A muted room arrives here as `isNoisy == false`, and that is the only thing standing
    /// between the user and a sound they explicitly asked not to hear.
    @Test("the push rules decide whether it makes a sound")
    func loudnessComesFromThePushRules() {
        func noisiness(_ isNoisy: Bool?) -> Bool? {
            let invite = Self.item(.invite(sender: "@anya:matrix.org"),
                                   room: Self.room(named: "Кухня"),
                                   sender: Self.sender(named: "Аня"),
                                   isNoisy: isNoisy ?? false)
            guard case let .show(notification) = PushMapper.outcome(for: invite,
                                                                    roomID: "!r",
                                                                    eventID: "$e") else { return nil }
            return notification.isNoisy
        }

        #expect(noisiness(true) == true)
        #expect(noisiness(false) == false)
    }
}
