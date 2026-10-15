import Foundation
import MatrixRustSDK

/// The words under a photo, a video or a file, in the shape `UploadParameters` takes them.
///
/// A text message is handed to the SDK as Markdown and it makes the HTML itself
/// (`messageEventContentFromMarkdown`). A caption cannot go that way: `UploadParameters` asks for the
/// plain body and the `FormattedBody` separately, and the FFI has no Markdown-to-HTML on its own. So
/// the HTML is made here, from the same Markdown the composer already produces for a message —
/// `ComposerMentions` for the links, `ComposerMarkdown` for the stars — parsed by Foundation, inline
/// only, because a caption is a line or two and not a document.
///
/// What is written as HTML is the subset `MatrixHTML` draws back: bold, italic, struck out, code,
/// links. `formatted` is nil when the caption has none of it — a plain caption carries a plain body
/// and nothing else, as other clients send it.
public struct MediaCaption: Equatable, Sendable {
    public let body: String
    public let html: String?
    public let mentionedUserIDs: [String]

    public init?(text: String, mentions: [ComposerMention]) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let (markdown, userIDs) = ComposerMentions.markdown(from: trimmed, mentions: mentions)
        mentionedUserIDs = userIDs

        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard let parsed = try? AttributedString(markdown: ComposerMarkdown.commonMark(from: markdown),
                                                 options: options) else {
            body = trimmed
            html = nil
            return
        }

        var html = ""
        var formatted = false
        for run in parsed.runs {
            var piece = Self.escaped(String(parsed[run.range].characters))
            let intent = run.inlinePresentationIntent ?? []
            if intent.contains(.code) { piece = "<code>\(piece)</code>"; formatted = true }
            if intent.contains(.strikethrough) { piece = "<del>\(piece)</del>"; formatted = true }
            if intent.contains(.emphasized) { piece = "<em>\(piece)</em>"; formatted = true }
            if intent.contains(.stronglyEmphasized) { piece = "<strong>\(piece)</strong>"; formatted = true }
            if let link = run.link {
                piece = "<a href=\"\(Self.escaped(link.absoluteString))\">\(piece)</a>"
                formatted = true
            }
            html += piece
        }
        self.html = formatted ? html.replacingOccurrences(of: "\n", with: "<br>") : nil
        // The body is the Markdown, as the SDK makes it for a message: it is what a client without
        // HTML shows, and what `ComposerMentions.unlinked` reads back into the composer for an
        // edit — a body of bare names would lose who was mentioned the moment the caption was
        // changed. A caption with nothing in it to format goes exactly as typed.
        body = formatted ? ComposerMarkdown.commonMark(from: markdown) : trimmed
    }

    /// The three fields of `UploadParameters` that are the caption.
    var formattedBody: FormattedBody? {
        html.map { FormattedBody(format: .html, body: $0) }
    }

    var mentions: Mentions? {
        mentionedUserIDs.isEmpty ? nil : Mentions(userIds: mentionedUserIDs, room: false)
    }

    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
