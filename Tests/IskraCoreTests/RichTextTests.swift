import Foundation
import Testing
@testable import IskraCore

@Suite("RichText")
struct RichTextTests {
    // Small readers so the assertions talk about runs, not attribute plumbing.
    private func links(_ attributed: AttributedString) -> [(String, URL)] {
        attributed.runs.compactMap { run in
            guard let url = run.link else { return nil }
            return (String(attributed[run.range].characters), url)
        }
    }

    private func mentions(_ attributed: AttributedString) -> [(text: String, userID: String, isSelf: Bool)] { // swiftlint:disable:this large_tuple
        attributed.runs.compactMap { run in
            guard let userID = run.iskra.mentionUserID else { return nil }
            return (String(attributed[run.range].characters), userID, run.iskra.mentionIsSelf ?? false)
        }
    }

    // MARK: - Plain text

    @Test("plain text with nothing to mark comes back untouched")
    func plainTextIsNoOp() {
        let attributed = RichText.attributed(body: "just a normal sentence, nothing to see")
        #expect(links(attributed).isEmpty)
        #expect(mentions(attributed).isEmpty)
        #expect(String(attributed.characters) == "just a normal sentence, nothing to see")
    }

    @Test("an empty body is safe")
    func emptyBody() {
        let attributed = RichText.attributed(body: "")
        #expect(String(attributed.characters).isEmpty)
        #expect(links(attributed).isEmpty)
    }

    // MARK: - Links

    @Test("a bare URL becomes a link run carrying its URL")
    func detectsURL() {
        let attributed = RichText.attributed(body: "see https://matrix.org for more")
        let found = links(attributed)
        #expect(found.count == 1)
        #expect(found.first?.0 == "https://matrix.org")
        #expect(found.first?.1 == URL(string: "https://matrix.org"))
    }

    @Test("two URLs are both marked, and the words between them are not")
    func detectsMultipleURLs() {
        let attributed = RichText.attributed(body: "a https://a.example and b http://b.example end")
        let found = links(attributed)
        #expect(found.count == 2)
        #expect(found.map(\.0).contains("https://a.example"))
        #expect(found.map(\.0).contains("http://b.example"))
    }

    @Test("the link's range lands on the URL, not the surrounding text")
    func linkRangeIsExact() {
        // A repeated word around the URL would catch a range-mapping bug that searched by substring.
        let attributed = RichText.attributed(body: "go go https://matrix.org go go")
        let found = links(attributed)
        #expect(found.count == 1)
        #expect(found.first?.0 == "https://matrix.org")
    }

    // MARK: - Mentions

    @Test("a mentioned user ID in the body is marked")
    func marksUserIDMention() {
        let attributed = RichText.attributed(
            body: "hey @alice:matrix.org are you there",
            mentionedUserIDs: ["@alice:matrix.org"]
        )
        let found = mentions(attributed)
        #expect(found.count == 1)
        #expect(found.first?.text == "@alice:matrix.org")
        #expect(found.first?.userID == "@alice:matrix.org")
        #expect(found.first?.isSelf == false)
    }

    @Test("a mention written as @DisplayName is marked when the name is known")
    func marksDisplayNameMention() {
        let attributed = RichText.attributed(
            body: "hey @Alice come look",
            mentionedUserIDs: ["@alice:matrix.org"],
            displayNames: ["@alice:matrix.org": "Alice"]
        )
        let found = mentions(attributed)
        #expect(found.contains { $0.text == "@Alice" && $0.userID == "@alice:matrix.org" })
    }

    @Test("your own mention is flagged as self")
    func flagsOwnMention() {
        let attributed = RichText.attributed(
            body: "ping @me:matrix.org please",
            mentionedUserIDs: ["@me:matrix.org"],
            ownUserID: "@me:matrix.org"
        )
        let found = mentions(attributed)
        #expect(found.count == 1)
        #expect(found.first?.isSelf == true)
    }

    @Test("a bare display name without @ is left alone, to avoid painting ordinary words")
    func bareNameIsNotAMention() {
        let attributed = RichText.attributed(
            body: "Sam went to the sam shop",
            mentionedUserIDs: ["@sam:matrix.org"],
            displayNames: ["@sam:matrix.org": "Sam"]
        )
        #expect(mentions(attributed).isEmpty)
    }

    @Test("a user the event did not mention is not marked even if their ID appears")
    func onlyMentionsFromTheSet() {
        let attributed = RichText.attributed(
            body: "quoting @bob:matrix.org from earlier",
            mentionedUserIDs: []
        )
        #expect(mentions(attributed).isEmpty)
    }

    @Test("links and mentions coexist in one body")
    func linksAndMentionsTogether() {
        let attributed = RichText.attributed(
            body: "@alice:matrix.org see https://matrix.org",
            mentionedUserIDs: ["@alice:matrix.org"]
        )
        #expect(links(attributed).count == 1)
        #expect(mentions(attributed).count == 1)
    }
}
