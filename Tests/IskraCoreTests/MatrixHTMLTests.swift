import Foundation
import Testing
@testable import IskraCore

/// The HTML a message carries, as the bubble will draw it. The rule these hold above all is that
/// the words survive: whatever is not understood is dropped as markup and kept as text.
@Suite("Matrix HTML")
struct MatrixHTMLTests {
    private func text(_ html: String) -> String? {
        MatrixHTML.attributed(html).map { String($0.characters) }
    }

    /// The intent on the run that holds `word`.
    private func intent(of word: String, in html: String) -> InlinePresentationIntent? {
        guard let attributed = MatrixHTML.attributed(html),
              let range = attributed.range(of: word) else { return nil }
        return attributed[range].runs.first?.inlinePresentationIntent
    }

    @Test("bold, italic, strikethrough and code become intents, nested ones combined")
    func inlineIntents() {
        let html = "<b>bold</b> <em>it</em> <del>gone</del> <code>x()</code> <strong><i>both</i></strong>"
        #expect(text(html) == "bold it gone x() both")
        #expect(intent(of: "bold", in: html) == .stronglyEmphasized)
        #expect(intent(of: "it", in: html) == .emphasized)
        #expect(intent(of: "gone", in: html) == .strikethrough)
        #expect(intent(of: "x()", in: html) == .code)
        #expect(intent(of: "both", in: html) == [.stronglyEmphasized, .emphasized])
    }

    @Test("a link keeps its address; a scheme that is not allowed is words")
    func links() throws {
        let attributed = try #require(MatrixHTML.attributed(#"<a href="https://iskra.chat">site</a> <a href="javascript:alert(1)">bad</a>"#))
        let site = try #require(attributed.range(of: "site"))
        #expect(attributed[site].link == URL(string: "https://iskra.chat"))
        let bad = try #require(attributed.range(of: "bad"))
        #expect(attributed[bad].link == nil)
    }

    @Test("a matrix.to pill is a mention, and knows when it is you")
    func mentions() throws {
        let html = #"<a href="https://matrix.to/#/%40alice%3Amatrix.org">Alice</a> and <a href="https://matrix.to/#/@me:x.org">Me</a>"#
        let attributed = try #require(MatrixHTML.attributed(html, ownUserID: "@me:x.org"))
        let alice = try #require(attributed.range(of: "Alice"))
        #expect(attributed[alice].iskra.mentionUserID == "@alice:matrix.org")
        #expect(attributed[alice].iskra.mentionIsSelf == false)
        #expect(attributed[alice].link == nil)
        let me = try #require(attributed.range(of: "Me"))
        #expect(attributed[me].iskra.mentionIsSelf == true)
    }

    @Test("the reply fallback is dropped whole")
    func replyFallback() {
        let html = "<mx-reply><blockquote><a href=\"https://matrix.to/#/!r/$e\">In reply to</a> <b>old</b></blockquote></mx-reply>new answer"
        #expect(text(html) == "new answer")
    }

    @Test("paragraphs, breaks and lists become lines")
    func blocks() {
        #expect(text("<p>one</p>\n<p>two</p>") == "one\n\ntwo")
        #expect(text("a<br>b<br/>c") == "a\nb\nc")
        #expect(text("<ul>\n<li>milk</li>\n<li>bread</li>\n</ul>") == "• milk\n• bread")
        #expect(text("<ol start=\"3\"><li>c</li><li><p>d</p></li></ol>") == "3. c\n4. d")
        #expect(text("<p>before</p><ul><li>x</li></ul><p>after</p>") == "before\n\n• x\n\nafter")
    }

    @Test("a quote's lines carry a bar and the quote attribute")
    func quotes() throws {
        let attributed = try #require(MatrixHTML.attributed("<blockquote>wise words</blockquote>said"))
        #expect(String(attributed.characters) == "▍wise words\n\nsaid")
        let words = try #require(attributed.range(of: "wise"))
        #expect(attributed[words].iskra.quote == true)
    }

    @Test("pre keeps its whitespace; elsewhere whitespace collapses")
    func whitespace() {
        #expect(text("<pre><code>let x = 1\n    y</code></pre>") == "let x = 1\n    y")
        #expect(text("lots   of\n\n spaces") == "lots of spaces")
    }

    @Test("entities are decoded, unknown tags dropped, images are their alt")
    func leftovers() {
        #expect(text("a &amp; b &lt;c&gt; &#128512; &#x41;") == "a & b <c> 😀 A")
        #expect(text("<marquee>still here</marquee>") == "still here")
        #expect(text(#"hi <img src="mxc://x/y" alt=":wave:">"#) == "hi :wave:")
    }

    @Test("spoilers and underline are marked for the bubble")
    func spoilers() throws {
        let attributed = try #require(MatrixHTML.attributed("<span data-mx-spoiler>secret</span> <u>under</u> <span data-mx-spoiler=\"why\">two</span>"))
        let secret = try #require(attributed.range(of: "secret"))
        #expect(attributed[secret].iskra.spoiler == 0)
        let two = try #require(attributed.range(of: "two"))
        #expect(attributed[two].iskra.spoiler == 1)
        let under = try #require(attributed.range(of: "under"))
        #expect(attributed[under].iskra.underline == true)
    }

    @Test("a misnested tag cannot leave bold on for the rest of the message")
    func misnested() {
        let html = "<b>bold <i>both</b> plain"
        #expect(intent(of: "plain", in: html) == nil)
    }

    @Test("HTML with no words in it gives way to the plain body")
    func empty() {
        #expect(MatrixHTML.attributed("<p> </p><br>") == nil)
        let fallback = RichText.attributed(body: "plain words", formattedBody: "<p></p>")
        #expect(String(fallback.characters) == "plain words")
    }

    @Test("bare addresses in formatted text still become links")
    func bareLinks() throws {
        let attributed = RichText.attributed(body: "", formattedBody: "<b>see</b> https://example.com now")
        let range = try #require(attributed.range(of: "https://example.com"))
        #expect(attributed[range].link == URL(string: "https://example.com"))
    }

    // MARK: - What a sender can throw at it

    @Test("a list starting at Int.max does not trap")
    func hugeListStart() {
        #expect(text("<ol start=\"9223372036854775807\"><li>a</li><li>b</li></ol>") != nil)
        #expect(text("<ol start=\"-5\"><li>a</li></ol>") == "0. a")
    }

    @Test("a body of brackets with no closing one is words, and quick")
    func unclosedBrackets() {
        let html = String(repeating: "<", count: 60_000) + " end"
        let started = ContinuousClock.now
        #expect(text(html)?.hasSuffix("end") == true)
        #expect(ContinuousClock.now - started < .seconds(2))
    }

    @Test("absurd nesting keeps its words and finishes")
    func deepNesting() {
        let html = String(repeating: "<b>", count: 5_000) + "deep" + String(repeating: "</b>", count: 5_000)
        let started = ContinuousClock.now
        #expect(text(html) == "deep")
        #expect(ContinuousClock.now - started < .seconds(2))
    }

    @Test("a thousand paragraphs finish quickly")
    func manyParagraphs() {
        let html = String(repeating: "<p>x</p>", count: 4_000)
        let started = ContinuousClock.now
        #expect(text(html)?.hasPrefix("x\n\nx") == true)
        #expect(ContinuousClock.now - started < .seconds(2))
    }
}
