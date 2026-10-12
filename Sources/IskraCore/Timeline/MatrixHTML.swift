import Foundation

/// A message's `formatted_body` — the HTML Matrix carries beside the plain body — turned into an
/// `AttributedString` a bubble can draw: bold, italic, struck through, underlined, code, links,
/// mentions, quotes, lists, headings and spoilers.
///
/// **A parser of its own, not `NSAttributedString(html:)`.** That one hands the string to WebKit:
/// it is slow enough to stall a scroll, may only run on the main thread, and will go and fetch an
/// `<img src>` from wherever it points — from inside an encrypted conversation, to an address the
/// sender chose. What Matrix allows in a message is a short list of tags (the spec's
/// `m.room.message` HTML subset), and a list that short is a tokenizer and a stack.
///
/// What it does with what it cannot draw is the rule worth knowing: **the words always survive.**
/// An unknown tag is dropped and its text kept; a `<table>` is its cells' words in order; an image
/// is its `alt`. The one thing thrown away whole is `<mx-reply>`, which is the quoted original a
/// reply drags along for clients that cannot show replies — this one shows them (`ReplyQuote`), and
/// would otherwise draw the question twice.
///
/// Block structure becomes characters, because SwiftUI's `Text` draws no block intents: paragraphs
/// become blank lines, list items become "• " and "1. ", a quote's lines start with a bar. Inline
/// structure becomes Foundation's own `inlinePresentationIntent`, which `Text` does draw; the few it
/// has no word for (underline, spoiler, quote, heading) are this app's attributes in
/// `AttributeScopes.IskraScope`, for the bubble to paint.
public enum MatrixHTML {
    /// The attributed text, or nil for an HTML body with no words in it — the caller then draws the
    /// plain body instead, which is what it would have done anyway.
    public static func attributed(_ html: String, ownUserID: String? = nil) -> AttributedString? {
        var parser = Parser(ownUserID: ownUserID)
        parser.run(html)
        let result = parser.finish()
        return result.characters.contains(where: { !$0.isWhitespace }) ? result : nil
    }

    /// The schemes a link may have. Anything else — `javascript:`, `file:`, a custom scheme that
    /// opens another app — is drawn as words.
    static let allowedSchemes: Set<String> = ["http", "https", "mailto", "matrix"]

    /// The Matrix ID a `matrix.to` link names, when it names a person — the pill a mention is.
    static func mentionedUser(in href: String) -> String? {
        let prefixes = ["https://matrix.to/#/", "http://matrix.to/#/"]
        guard let prefix = prefixes.first(where: href.hasPrefix) else {
            if href.hasPrefix("matrix:u/") {
                let id = href.dropFirst("matrix:u/".count).prefix { $0 != "?" }
                return id.isEmpty ? nil : "@" + id
            }
            return nil
        }
        let rest = href.dropFirst(prefix.count).prefix { $0 != "?" }
        let decoded = String(rest).removingPercentEncoding ?? String(rest)
        guard decoded.hasPrefix("@"), decoded.contains(":") else { return nil }
        return decoded
    }

    // MARK: - The parser

    private struct Parser {
        let ownUserID: String?

        var output = AttributedString()
        /// The open elements, innermost last, each with what it contributes to the text inside it.
        var stack: [Element] = []
        /// Inside `<mx-reply>`: everything is dropped until it closes.
        var skipping = 0
        /// The number of each open list's next item; nil for a bulleted one.
        var lists: [Int?] = []
        var spoilers = 0

        struct Element {
            let name: String
            var intent: InlinePresentationIntent = []
            var link: URL?
            var mention: String?
            var underline = false
            var spoiler: Int?
            var quote = false
            var heading: Int?
            var preformatted = false
        }

        init(ownUserID: String?) {
            self.ownUserID = ownUserID
        }

        static let maximumDepth = 64
        static let maximumListNumber = 1_000_000

        mutating func run(_ html: String) {
            var index = html.startIndex
            var text = ""

            // Linear, and that is a promise kept against the sender. A `<` is answered by looking
            // for its `>` — and if there is none, there will be none for any later `<` either, so
            // the rest is words and the search is not made again. Asking afresh at every `<` was a
            // rescan to the end of the message per bracket: a 64 KB body of them, quadratic.
            var tagsPossible = true
            while index < html.endIndex {
                let character = html[index]
                if character == "<", tagsPossible {
                    guard let close = html[index...].firstIndex(of: ">") else {
                        tagsPossible = false
                        continue
                    }
                    if !text.isEmpty {
                        append(text: Self.decodeEntities(text))
                        text = ""
                    }
                    tag(String(html[html.index(after: index)..<close]))
                    index = html.index(after: close)
                } else {
                    text.append(character)
                    index = html.index(after: index)
                }
            }
            if !text.isEmpty { append(text: Self.decodeEntities(text)) }
        }

        mutating func finish() -> AttributedString {
            // Trailing blank lines from a last paragraph or list: the bubble ends at the last word.
            while let last = output.characters.last, last.isWhitespace {
                output.characters.removeLast()
            }
            return output
        }

        // MARK: Tags

        mutating func tag(_ raw: String) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("!"), !trimmed.hasPrefix("?") else { return }

            if trimmed.hasPrefix("/") {
                close(String(trimmed.dropFirst()).lowercased().trimmingCharacters(in: .whitespaces))
                return
            }

            let selfClosing = trimmed.hasSuffix("/")
            let body = selfClosing ? String(trimmed.dropLast()) : trimmed
            let name = String(body.prefix { !$0.isWhitespace }).lowercased()
            let attributes = Self.attributes(String(body.dropFirst(name.count)))

            if name == "mx-reply" {
                if !selfClosing { skipping += 1 }
                return
            }
            guard skipping == 0 else { return }

            switch name {
            case "br":
                appendRaw("\n")
                return
            case "hr":
                breakBlock()
                appendRaw("———")
                breakBlock()
                return
            case "img":
                // Never fetched — see the type's note. A custom emoji's alt is its ":name:".
                if let alt = attributes["alt"] ?? attributes["title"], !alt.isEmpty {
                    append(text: alt)
                }
                return
            default:
                break
            }

            // Past this depth nothing new is opened — its words still come through, unstyled.
            // Every run of text walks the stack, so an unbounded one is quadratic in a sender's
            // hands; no message anybody wrote nests sixty-four deep.
            guard !selfClosing, stack.count < Self.maximumDepth else { return }

            var element = Element(name: name)
            switch name {
            case "b", "strong":
                element.intent = .stronglyEmphasized
            case "i", "em", "cite":
                element.intent = .emphasized
            case "s", "del", "strike":
                element.intent = .strikethrough
            case "u", "ins":
                element.underline = true
            case "code":
                element.intent = .code
            case "pre":
                breakBlock()
                element.intent = .code
                element.preformatted = true
            case "a":
                let href = attributes["href"] ?? ""
                if let user = MatrixHTML.mentionedUser(in: href) {
                    element.mention = user
                } else if let url = URL(string: href), let scheme = url.scheme?.lowercased(),
                          MatrixHTML.allowedSchemes.contains(scheme) {
                    element.link = url
                }
            case "span", "font":
                if attributes["data-mx-spoiler"] != nil {
                    element.spoiler = spoilers
                    spoilers += 1
                }
            case "p", "div":
                // A paragraph inside a list item is the item's text, not a block of its own —
                // breaking here would leave the bullet alone on its line.
                if !stack.contains(where: { $0.name == "li" }) { breakBlock(blank: true) }
            case "blockquote":
                breakBlock(blank: true)
                element.quote = true
            case "h1", "h2", "h3", "h4", "h5", "h6":
                breakBlock(blank: true)
                element.heading = Int(name.dropFirst()) ?? 1
                element.intent = .stronglyEmphasized
            case "ul":
                breakBlock()
                lists.append(nil)
            case "ol":
                breakBlock()
                // Clamped: the sender writes `start`, and `Int.max` plus one is a trap, not a number.
                let start = Int(attributes["start"] ?? "") ?? 1
                lists.append(min(max(start, 0), Self.maximumListNumber))
            case "li":
                breakBlock()
                let depth = max(0, lists.count - 1)
                let indent = String(repeating: "    ", count: depth)
                if let number = lists.last ?? nil {
                    appendRaw("\(indent)\(number). ")
                    lists[lists.count - 1] = min(number + 1, Self.maximumListNumber)
                } else {
                    appendRaw("\(indent)• ")
                }
            default:
                break
            }
            stack.append(element)
        }

        mutating func close(_ name: String) {
            if name == "mx-reply" {
                skipping = max(0, skipping - 1)
                return
            }
            guard skipping == 0 else { return }

            // Close up to the matching element, so a stray or misnested tag cannot leave bold on
            // for the rest of the message.
            guard let position = stack.lastIndex(where: { $0.name == name }) else { return }
            stack.removeSubrange(position...)

            switch name {
            case "p", "div":
                if stack.contains(where: { $0.name == "li" }) { breakBlock() } else { breakBlock(blank: true) }
            case "blockquote", "h1", "h2", "h3", "h4", "h5", "h6":
                breakBlock(blank: true)
            case "pre", "li":
                breakBlock()
            case "ul", "ol":
                if !lists.isEmpty { lists.removeLast() }
                breakBlock()
            default:
                break
            }
        }

        // MARK: Text

        var isPreformatted: Bool { stack.contains(where: \.preformatted) }

        mutating func append(text: String) {
            guard skipping == 0 else { return }
            var text = text
            if !isPreformatted {
                // HTML's whitespace rule: any run of it is one space, and none at the start of a line.
                text = text.replacing(/\s+/, with: " ")
                if output.characters.isEmpty || output.characters.last == "\n" {
                    text = String(text.drop(while: { $0 == " " }))
                }
                if text.hasPrefix(" "), output.characters.last == " " {
                    text.removeFirst()
                }
            }
            guard !text.isEmpty else { return }

            // A quote's bar goes in front of each of its lines.
            if stack.contains(where: \.quote) {
                if output.characters.isEmpty || output.characters.last == "\n" {
                    appendRaw("▍", quote: true)
                }
                text = text.replacingOccurrences(of: "\n", with: "\n▍")
            }

            var run = AttributedString(text)
            var intent: InlinePresentationIntent = []
            for element in stack {
                intent.formUnion(element.intent)
                if let link = element.link { run.link = link }
                if let mention = element.mention {
                    run.iskra.mentionUserID = mention
                    run.iskra.mentionIsSelf = (mention == ownUserID)
                }
                if element.underline { run.iskra.underline = true }
                if let spoiler = element.spoiler { run.iskra.spoiler = spoiler }
                if element.quote { run.iskra.quote = true }
                if let heading = element.heading { run.iskra.heading = heading }
            }
            if !intent.isEmpty { run.inlinePresentationIntent = intent }
            output.append(run)
        }

        /// Characters that are structure, not words — a bullet, a line break.
        mutating func appendRaw(_ text: String, quote: Bool = false) {
            var run = AttributedString(text)
            if quote { run.iskra.quote = true }
            output.append(run)
        }

        /// Ends the line, if it is not ended already — and with `blank`, leaves an empty one after
        /// it, which is how a paragraph is told from the next.
        mutating func breakBlock(blank: Bool = false) {
            guard let last = output.characters.last else { return }
            // A trailing space before the break is not part of anything.
            if last == " " { output.characters.removeLast() }
            if output.characters.last != "\n" { appendRaw("\n") }
            // The last two characters, not a count of all of them — `count` on an attributed
            // string walks it, and a message of a thousand paragraphs would walk it a thousand times.
            if blank, Array(output.characters.suffix(2)) != ["\n", "\n"] {
                appendRaw("\n")
            }
        }

        // MARK: Helpers

        /// `name="value"`, `name='value'`, `name=value` and a bare `name`, lowercased by name.
        static func attributes(_ source: String) -> [String: String] {
            var result: [String: String] = [:]
            let pattern = /([A-Za-z_:][-A-Za-z0-9_:.]*)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+)))?/
            for match in source.matches(of: pattern) {
                let name = String(match.1).lowercased()
                let value = match.2 ?? match.3 ?? match.4
                result[name] = value.map { MatrixHTML.Parser.decodeEntities(String($0)) } ?? ""
            }
            return result
        }

        static func decodeEntities(_ text: String) -> String {
            guard text.contains("&") else { return text }
            var result = ""
            var index = text.startIndex
            while index < text.endIndex {
                if text[index] == "&", let semicolon = text[index...].prefix(12).firstIndex(of: ";") {
                    let name = text[text.index(after: index)..<semicolon]
                    if let decoded = entity(String(name)) {
                        result.append(decoded)
                        index = text.index(after: semicolon)
                        continue
                    }
                }
                result.append(text[index])
                index = text.index(after: index)
            }
            return result
        }

        static func entity(_ name: String) -> String? {
            switch name {
            case "amp": return "&"
            case "lt": return "<"
            case "gt": return ">"
            case "quot": return "\""
            case "apos": return "'"
            case "nbsp": return "\u{00A0}"
            default:
                let scalar: UInt32?
                if name.hasPrefix("#x") || name.hasPrefix("#X") {
                    scalar = UInt32(name.dropFirst(2), radix: 16)
                } else if name.hasPrefix("#") {
                    scalar = UInt32(name.dropFirst())
                } else {
                    scalar = nil
                }
                return scalar.flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            }
        }
    }
}

// MARK: - The attributes `Text` has no word for

/// Underlined — `<u>`. Foundation's intents have no underline, and `underlineStyle` is a UI
/// framework's attribute, which this target does not import.
public enum UnderlineAttribute: AttributedStringKey {
    public typealias Value = Bool
    public static let name = "moscow.swag.iskra.underline"
}

/// Hidden until tapped — `<span data-mx-spoiler>`. The value tells one spoiler in a message from
/// another, so each is revealed by its own tap.
public enum SpoilerAttribute: AttributedStringKey {
    public typealias Value = Int
    public static let name = "moscow.swag.iskra.spoiler"
}

/// Inside a `<blockquote>` — drawn quieter, with a bar in front of each line.
public enum QuoteAttribute: AttributedStringKey {
    public typealias Value = Bool
    public static let name = "moscow.swag.iskra.quote"
}

/// A heading, `<h1>` to `<h6>` — the level, for the bubble to size.
public enum HeadingAttribute: AttributedStringKey {
    public typealias Value = Int
    public static let name = "moscow.swag.iskra.heading"
}
