import Testing
@testable import IskraCore

/// The "@" list in the composer: when it is asking, who it finds, and what is sent.
@Suite struct ComposerMentionsTests {
    private func member(_ id: String, _ name: String) -> RoomMemberSummary {
        RoomMemberSummary(id: id, name: name, avatarURL: nil, role: .member,
                          authority: .level(0), isNameAmbiguous: false)
    }

    private func query(_ text: String) -> MentionQuery? {
        ComposerMentions.query(in: text, cursor: text.endIndex)
    }

    @Test func anAtAtTheStartOrAfterASpaceIsAsking() {
        #expect(query("@")?.text == "")
        #expect(query("привет @ка")?.text == "ка")
        #expect(query("(@kai")?.text == "kai")
    }

    @Test func anAddressIsNotAMention() {
        #expect(query("boris@mail") == nil)
    }

    @Test func aSpaceEndsTheQuestion() {
        #expect(query("@kai ") == nil)
        #expect(query("@kai guo") == nil)
    }

    @Test func theQueryIsWhereTheCursorIs() {
        let text = "@kai and more"
        let cursor = text.index(text.startIndex, offsetBy: 4)
        #expect(ComposerMentions.query(in: text, cursor: cursor)?.text == "kai")
    }

    @Test func anyWordOfTheNameOrTheIDMatches() {
        let members = [member("@kai:matrix.org", "Kai Guo"),
                       member("@ezh:matrix.org", "Ёжик"),
                       member("@mx:matrix.org", "Émile")]
        #expect(ComposerMentions.matches("gu", in: members).map(\.id) == ["@kai:matrix.org"])
        #expect(ComposerMentions.matches("KAI", in: members).map(\.id) == ["@kai:matrix.org"])
        #expect(ComposerMentions.matches("еж", in: members).map(\.id) == ["@ezh:matrix.org"])
        #expect(ComposerMentions.matches("emi", in: members).map(\.id) == ["@mx:matrix.org"])
        #expect(ComposerMentions.matches("mx", in: members).map(\.id) == ["@mx:matrix.org"])
        #expect(ComposerMentions.matches("", in: members).count == 3)
    }

    @Test func pickingPutsTheNameInWithASpace() {
        let text = "hi @ka"
        let found = try! #require(query(text))
        let (result, cursor, mention) = ComposerMentions.insert(member("@kai:m.org", "Kai Guo"), replacing: found, in: text)
        #expect(result == "hi @Kai Guo ")
        #expect(cursor == result.count)
        #expect(mention == ComposerMention(userID: "@kai:m.org", name: "Kai Guo"))
    }

    @Test func aSurvivingMentionBecomesALink() {
        let mentions = [ComposerMention(userID: "@kai:m.org", name: "Kai Guo")]
        let (markdown, ids) = ComposerMentions.markdown(from: "hi @Kai Guo, see you", mentions: mentions)
        #expect(markdown == "hi [@Kai Guo](https://matrix.to/#/@kai:m.org), see you")
        #expect(ids == ["@kai:m.org"])
    }

    @Test func aDeletedMentionPingsNobody() {
        let mentions = [ComposerMention(userID: "@kai:m.org", name: "Kai")]
        let (markdown, ids) = ComposerMentions.markdown(from: "hi Ka", mentions: mentions)
        #expect(markdown == "hi Ka")
        #expect(ids.isEmpty)
    }

    @Test func aShortNameIsNotFoundInsideALongerOne() {
        let mentions = [ComposerMention(userID: "@ann:m.org", name: "Ann"),
                        ComposerMention(userID: "@anna:m.org", name: "Anna")]
        let (markdown, ids) = ComposerMentions.markdown(from: "@Anna", mentions: mentions)
        #expect(markdown == "[@Anna](https://matrix.to/#/@anna:m.org)")
        #expect(ids == ["@anna:m.org"])
    }

    @Test func markupInANameIsEscapedAndComesBack() {
        let mentions = [ComposerMention(userID: "@x:m.org", name: "*star* [x]")]
        let (markdown, _) = ComposerMentions.markdown(from: "@*star* [x] hi", mentions: mentions)
        #expect(markdown == #"[@\*star\* \[x\]](https://matrix.to/#/@x:m.org) hi"#)
        // Single stars stay escaped through the messenger-style bold pass.
        #expect(ComposerMarkdown.commonMark(from: markdown) == markdown)

        let (text, back) = ComposerMentions.unlinked(markdown)
        #expect(text == "@*star* [x] hi")
        #expect(back == mentions)
    }
}
