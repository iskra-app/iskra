import Foundation

/// What people type into the composer, turned into the Markdown the SDK speaks.
///
/// The two disagree about one character. In CommonMark `*this*` and `_this_` are the same thing —
/// emphasis, drawn in italics — and bold takes two stars. In every messenger people actually use,
/// one star is **bold** and the underscore is the italic, and that is what gets typed: `*важно*
/// _кстати_` came out as two italic words, which reads as the app ignoring half of what was asked.
///
/// So a single pair of stars becomes a double pair before the SDK sees it, and nothing else is
/// touched. `**this**` was already bold and stays so; a bullet (`* item`) has a space after its star
/// and is not a pair; `2*3*4` has letters against its stars and is arithmetic; and inside code —
/// a `span` or a fenced block — a star is a star.
public enum ComposerMarkdown {
    public static func commonMark(from text: String) -> String {
        var result = ""
        var rest = text[...]
        while let code = rest.range(of: codePattern, options: .regularExpression) {
            result += boldenStars(in: String(rest[..<code.lowerBound]))
            result += rest[code]
            rest = rest[code.upperBound...]
        }
        result += boldenStars(in: String(rest))
        return result
    }

    /// A fenced block, or an inline span — what must be passed through exactly as typed.
    private static let codePattern = "```[\\s\\S]*?```|`[^`\\n]+`"

    private static let singleStars = try! NSRegularExpression(
        pattern: #"(?<![\*\\\w])\*(?![\s\*])([^\*\n]*?[^\s\*\\])\*(?![\*\w])"#
    )

    private static func boldenStars(in text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        return singleStars.stringByReplacingMatches(in: text, range: range, withTemplate: "**$1**")
    }
}
