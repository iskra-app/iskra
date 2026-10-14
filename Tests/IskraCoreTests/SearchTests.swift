import Testing
import MatrixRustSDK
@testable import IskraCore

/// What a search is allowed to give back.
///
/// The local index is keyed by event ID and keeps the words of every message it has seen. The
/// SDK removes a message from it when it sees the redaction — but only when it still holds the
/// original event in its event cache, which it does not for old history and does not at all
/// after the cache has been cleared. So the words of a deleted message can outlive the message,
/// and a query can still match them. What stops that from reaching the screen is `excerpt`,
/// and these are the tests that say so.
@Suite("Search results")
struct SearchTests {
    private func content(_ kind: MsgLikeKind) -> TimelineItemContent {
        .msgLike(content: MsgLikeContent(kind: kind,
                                         reactions: [],
                                         inReplyTo: nil,
                                         threadRoot: nil,
                                         threadSummary: nil))
    }

    private func message(_ body: String) -> MsgLikeKind {
        .message(content: MessageContent(msgType: .text(content: TextMessageContent(body: body,
                                                                                    formatted: nil)),
                                         body: body,
                                         isEdited: false,
                                         mentions: nil))
    }

    @Test("a message that still exists is a result, in its own words")
    func aLiveMessageIsAHit() {
        let hit = SearchStore.excerpt(for: content(message("ключи под ковриком")))
        #expect(hit == "ключи под ковриком")
    }

    /// The one that matters. A redacted event carries no words of its own, so nothing can be
    /// *printed* from it — but it was found by the words it used to have, and returning it at
    /// all would put a deleted message back on the screen, under its sender's name and the time
    /// it was sent. `MessagePreview` would happily render it as "Сообщение удалено"; a search
    /// result may not be that lenient.
    @Test("a deleted message is not a result at all")
    func aRedactedMessageIsNeverAHit() {
        #expect(SearchStore.excerpt(for: content(.redacted)) == nil)
    }

    /// The room list says "Сообщение удалено" for a redaction, and it is right to: the room
    /// still has a row where the message was. Search has no such row to label. The two rules
    /// are deliberately different, and this pins the difference so that a later tidy-up does
    /// not "simplify" search back onto the preview and reopen the hole.
    @Test("the chat list still labels a deletion, and search still refuses it")
    func previewAndSearchDisagreeOnPurpose() {
        let deleted = content(.redacted)

        #expect(MessagePreview.text(for: deleted) == String(core: CoreStrings.Preview.deleted))
        #expect(SearchStore.excerpt(for: deleted) == nil)
    }

    /// A message nobody can read cannot have been matched by its words, so a hit on one means
    /// the index is handing back something we did not put in it. Refuse it rather than show a
    /// row that says "Сообщение не читается" to a query it cannot possibly have matched.
    @Test("an undecryptable event is not a result")
    func anUnreadableMessageIsNeverAHit() {
        let unreadable = MsgLikeKind.unableToDecrypt(msg: .olmV1Curve25519AesSha2(senderKey: "key"))
        #expect(SearchStore.excerpt(for: content(unreadable)) == nil)
    }

    // The nickname given to a personal chat names the person it is with, and nobody else in it.
    @Test func nicknameGoesOnlyToTheCounterpart() {
        let name = { (sender: String) in
            SearchStore.senderName(sender, displayName: "anna_1987",
                                   counterpartID: "@anna:example.org", localName: "Мама")
        }
        #expect(name("@anna:example.org") == "Мама")
        // A third person invited into the chat keeps their own name — never the nickname.
        #expect(name("@mallory:example.org") == "anna_1987")
        #expect(SearchStore.senderName("@anna:example.org", displayName: nil,
                                       counterpartID: nil, localName: "Мама") == "@anna:example.org")
    }
}
