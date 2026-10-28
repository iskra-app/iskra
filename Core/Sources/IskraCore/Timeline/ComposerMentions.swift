import Foundation

/// Somebody picked from the "@" list in the composer — who, and the name that went into the text.
///
/// The composer's field holds plain words, so a mention is remembered beside the draft rather than
/// inside it: `@Kai Guo` in the text, and this record saying which Kai that was. At send the two are
/// matched up again (`ComposerMentions.markdown`), and a name the user has since deleted or retyped
/// simply is not a mention any more — the text is the truth, the record only says what it meant.
public struct ComposerMention: Sendable, Hashable {
    public let userID: String
    public let name: String

    public init(userID: String, name: String) {
        self.userID = userID
        self.name = name
    }

    /// What goes into the field, and what is looked for at send.
    public var token: String { "@" + name }
}

/// The "@" being typed right now: where it is in the draft, and what follows it so far.
public struct MentionQuery: Equatable {
    /// From the "@" up to the cursor — the part a picked name replaces.
    public let range: Range<String.Index>
    /// What is after the "@", which may be nothing yet.
    public let text: String
}

/// The arithmetic behind the "@" list — finding the query, choosing who matches it, putting the
/// name in, and turning what was picked into the Matrix a mention is. No views and no SDK, so all
/// of it can be asked questions in a test.
public enum ComposerMentions {
    /// Longest a query gets before it stops being one. Nobody types forty letters of a name to
    /// find it in a list, and a long word that happens to start with "@" should not keep the list up.
    static let longestQuery = 32

    /// The "@…" the cursor is at the end of, if it is at the end of one.
    ///
    /// An "@" counts only at the start of the text or after a space or an opening bracket —
    /// `boris@mail.ru` is an address, not somebody being called. The query stops at whitespace:
    /// names have spaces in them, but nobody types one to narrow a list that is already showing
    /// them, and an "@" left behind three words ago is not still asking.
    public static func query(in text: String, cursor: String.Index) -> MentionQuery? {
        guard cursor <= text.endIndex else { return nil }
        let before = text[..<cursor]
        guard let at = before.lastIndex(of: "@") else { return nil }

        let typed = before[before.index(after: at)...]
        guard typed.count <= longestQuery,
              !typed.contains(where: { $0.isWhitespace || $0 == "@" }) else { return nil }

        if at > text.startIndex {
            let previous = text[text.index(before: at)]
            guard previous.isWhitespace || "([{«\"'".contains(previous) else { return nil }
        }
        return MentionQuery(range: at..<cursor, text: String(typed))
    }

    /// Who the query could mean, best first.
    ///
    /// A match is the start of any word of the name, or the start of the Matrix ID's own part —
    /// "@gu" finds Kai Guo, and "@kai" finds `@kai:matrix.org` whatever he calls himself — and
    /// neither case nor accents count: "@ё" finds Ёжик, "@e" finds Émile. Order is the order given,
    /// which is the room's own (`TimelineStore.mentionCandidates` puts whoever spoke last first).
    public static func matches(_ query: String, in members: [RoomMemberSummary]) -> [RoomMemberSummary] {
        let needle = fold(query)
        guard !needle.isEmpty else { return members }
        return members.filter { member in
            let words = fold(member.name).split(whereSeparator: { $0.isWhitespace || $0 == "-" || $0 == "." })
            if words.contains(where: { $0.hasPrefix(needle) }) { return true }
            return fold(localpart(of: member.id)).hasPrefix(needle)
        }
    }

    /// The draft with `member` put in place of the query, and where the cursor goes after it.
    ///
    /// A space follows the name, so the next word can be typed straight away — unless there is one
    /// there already, in which case the cursor simply steps over it.
    public static func insert(_ member: RoomMemberSummary,
                              replacing query: MentionQuery,
                              in text: String) -> (text: String, cursor: Int, mention: ComposerMention) {
        let mention = ComposerMention(userID: member.id, name: member.name)
        let head = String(text[..<query.range.lowerBound])
        var tail = String(text[query.range.upperBound...])
        if tail.first?.isWhitespace != true { tail = " " + tail }
        let result = head + mention.token + tail
        // Counted in characters, which is what `TextSelection` is built from on the other side.
        let cursor = head.count + mention.token.count + 1
        return (result, cursor, mention)
    }

    /// The draft as Markdown with every surviving mention made a `matrix.to` link, and the IDs that
    /// survived — for `m.mentions`, which is what actually notifies them.
    ///
    /// The link is what other clients draw as a pill and `MatrixHTML` draws as a mention; the
    /// `m.mentions` set is what the push rules read. Both are needed: a link without the set pings
    /// nobody on a current server, and a set without the link shows a name nobody can tap.
    ///
    /// A mention survives only where its exact `@Name` is still in the text and is not merely the
    /// start of a longer word, so `@Ann` is not found inside `@Anna`. Longer names are placed first
    /// for the same reason.
    public static func markdown(from text: String, mentions: [ComposerMention]) -> (markdown: String, userIDs: [String]) {
        let unique = Array(Set(mentions)).sorted { $0.name.count > $1.name.count }
        guard !unique.isEmpty else { return (text, []) }

        // Found against the original text, all at once, so a link already written cannot be
        // searched again for a shorter name.
        var found: [(Range<String.Index>, ComposerMention)] = []
        for mention in unique {
            var start = text.startIndex
            while let range = text.range(of: mention.token, range: start..<text.endIndex) {
                start = range.upperBound
                if range.upperBound < text.endIndex, isWordCharacter(text[range.upperBound]) { continue }
                if range.lowerBound > text.startIndex, isWordCharacter(text[text.index(before: range.lowerBound)]) { continue }
                if found.contains(where: { $0.0.overlaps(range) }) { continue }
                found.append((range, mention))
            }
        }
        guard !found.isEmpty else { return (text, []) }

        found.sort { $0.0.lowerBound < $1.0.lowerBound }
        var result = ""
        var cursor = text.startIndex
        var userIDs: [String] = []
        for (range, mention) in found {
            result += text[cursor..<range.lowerBound]
            result += "[\(escaped(mention.token))](https://matrix.to/#/\(mention.userID))"
            cursor = range.upperBound
            if !userIDs.contains(mention.userID) { userIDs.append(mention.userID) }
        }
        result += text[cursor...]
        return (result, userIDs)
    }

    /// The other way: a message this app sent, back into the composer for an edit. Its body is the
    /// Markdown it was written as, so a mention in it is `[@Kai](https://matrix.to/#/@kai:…)` — and
    /// the field should say `@Kai` again, with the record beside it, so that the edit still pings.
    public static func unlinked(_ markdown: String) -> (text: String, mentions: [ComposerMention]) {
        let range = NSRange(markdown.startIndex..., in: markdown)
        var text = ""
        var mentions: [ComposerMention] = []
        var cursor = markdown.startIndex
        for match in linkPattern.matches(in: markdown, range: range) {
            guard let whole = Range(match.range, in: markdown),
                  let label = Range(match.range(at: 1), in: markdown),
                  let user = Range(match.range(at: 2), in: markdown) else { continue }
            let token = unescaped(String(markdown[label]))
            guard token.hasPrefix("@"), token.count > 1 else { continue }
            text += markdown[cursor..<whole.lowerBound]
            text += token
            cursor = whole.upperBound
            let mention = ComposerMention(userID: String(markdown[user]), name: String(token.dropFirst()))
            if !mentions.contains(mention) { mentions.append(mention) }
        }
        text += markdown[cursor...]
        return (text, mentions)
    }

    /// `[label](https://matrix.to/#/@user:server)`, with escaped characters allowed in the label.
    private static let linkPattern = try! NSRegularExpression(
        pattern: #"\[((?:\\.|[^\]\\])+)\]\(https://matrix\.to/#/(@[^)\s]+)\)"#
    )

    // MARK: - Pieces

    /// "kai" out of "@kai:matrix.org".
    static func localpart(of userID: String) -> String {
        var part = userID.hasPrefix("@") ? userID.dropFirst() : userID[...]
        if let colon = part.firstIndex(of: ":") { part = part[..<colon] }
        return String(part)
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .replacingOccurrences(of: "ё", with: "е")
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }

    /// A name is the user's own words, and Markdown would read `*`, `_` or a `]` in it as markup —
    /// a name with a bracket in it would close the link early.
    private static func unescaped(_ text: String) -> String {
        var result = ""
        var escaping = false
        for character in text {
            if !escaping, character == "\\" { escaping = true; continue }
            escaping = false
            result.append(character)
        }
        return result
    }

    private static func escaped(_ text: String) -> String {
        var result = ""
        for character in text {
            if "\\`*_[]()<>#~|!".contains(character) { result.append("\\") }
            result.append(character)
        }
        return result
    }
}
