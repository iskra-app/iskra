import Foundation
import MatrixRustSDK
import Testing
@testable import IskraCore

@Suite("ComposerMarkdown")
struct ComposerMarkdownTests {
    @Test func oneStarIsBoldAndTheUnderscoreItalic() {
        #expect(ComposerMarkdown.commonMark(from: "*markdown* _test_") == "**markdown** _test_")
    }

    @Test func whatWasAlreadyBoldStaysBold() {
        #expect(ComposerMarkdown.commonMark(from: "**жирный**") == "**жирный**")
        #expect(ComposerMarkdown.commonMark(from: "***оба***") == "***оба***")
    }

    @Test func starsThatAreNotAPairAreLeftAlone() {
        #expect(ComposerMarkdown.commonMark(from: "* пункт\n* ещё") == "* пункт\n* ещё")
        #expect(ComposerMarkdown.commonMark(from: "2*3*4") == "2*3*4")
        #expect(ComposerMarkdown.commonMark(from: "a * b * c") == "a * b * c")
        #expect(ComposerMarkdown.commonMark(from: "*a*") == "**a**")
    }

    @Test func codeIsPassedThroughAsTyped() {
        #expect(ComposerMarkdown.commonMark(from: "`*x*` и *y*") == "`*x*` и **y**")
        #expect(ComposerMarkdown.commonMark(from: "```\n*x*\n```") == "```\n*x*\n```")
    }

    @Test func thePreviewIsTheWordsWithoutTheMarks() {
        let formatted = FormattedBody(format: .html, body: "<strong>markdown</strong> <em>test</em>")
        #expect(MessagePreview.words("**markdown** _test_", formatted: formatted) == "markdown test")
        #expect(MessagePreview.words("просто текст", formatted: nil) == "просто текст")
    }
}
