import Foundation

/// Turns a message's plain body into an `AttributedString` with the two things a bubble has to be
/// able to draw over bare text: **links** and **mentions**.
///
/// It is a pure function on purpose. `MessageKind.text` still carries the raw `String` — the value
/// stays cheap to diff and `Equatable`, and nothing in the model layer holds an `AttributedString`
/// that SwiftUI would have to re-diff character by character. The transform runs at render time,
/// in the bubble, from inputs the mapper already has. Being pure is also what makes it testable
/// without a homeserver: feed it a string, read back the runs.
///
/// Two design notes:
/// - **Links** are marked with Foundation's own `\.link` attribute. That is what lets a view
///   intercept the tap through the `openURL` environment and show the "where does this really go?"
///   confirmation before anything opens — the URL is not hidden behind a custom key the view would
///   have to know to look for.
/// - **Mentions** are marked with the custom attributes in `AttributeScopes.IskraScope`, carrying
///   the mentioned user's ID and whether that user is *you*. Styling — the colour of your own name
///   versus someone else's — is the view's business; this only says where the mentions are.
public enum RichText {
    /// Builds the attributed body. `mentionedUserIDs` are the IDs the event says it mentions (the
    /// Matrix `m.mentions` set); `displayNames` maps any of those IDs to the name shown in the room,
    /// so both "@alice:matrix.org" and "@Alice" in the text light up; `ownUserID` is the one whose
    /// mention the view will want to paint differently.
    public static func attributed(body: String,
                                  mentionedUserIDs: Set<String> = [],
                                  displayNames: [String: String] = [:],
                                  ownUserID: String? = nil) -> AttributedString {
        var attributed = AttributedString(body)
        // Mentions first, then links. A Matrix user ID has a domain in it — "@alice:matrix.org" —
        // and the link detector will happily flag that "matrix.org" as a URL, cutting the mention in
        // half. Marking mentions first, then teaching the link pass to skip anything that overlaps a
        // mention, keeps a name a name.
        applyMentions(to: &attributed,
                      body: body,
                      mentionedUserIDs: mentionedUserIDs,
                      displayNames: displayNames,
                      ownUserID: ownUserID)
        applyLinks(to: &attributed, body: body)
        return attributed
    }

    /// The same, from the message's HTML when it has some — `MatrixHTML` draws the formatting, and
    /// then mentions and bare addresses are found in the words exactly as they are in a plain body.
    /// Falls back to the plain body when the HTML has nothing in it worth drawing.
    public static func attributed(body: String,
                                  formattedBody: String?,
                                  mentionedUserIDs: Set<String> = [],
                                  displayNames: [String: String] = [:],
                                  ownUserID: String? = nil) -> AttributedString {
        guard let formattedBody, var attributed = MatrixHTML.attributed(formattedBody, ownUserID: ownUserID) else {
            return Self.attributed(body: body, mentionedUserIDs: mentionedUserIDs,
                                   displayNames: displayNames, ownUserID: ownUserID)
        }
        let text = String(attributed.characters)
        applyMentions(to: &attributed, body: text, mentionedUserIDs: mentionedUserIDs,
                      displayNames: displayNames, ownUserID: ownUserID)
        applyLinks(to: &attributed, body: text)
        return attributed
    }

    // MARK: - Links

    /// The one detector, built once. `NSDataDetector` is not cheap to spin up, and it is not
    /// mutable state — the same instance is safe to reuse across calls and threads.
    private static let linkDetector: NSDataDetector? =
        try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// Every address in a message, in the order they were written.
    ///
    /// The same detector the bubble paints with, asked a different question: not "where in this
    /// sentence are the links" but "which links are in it". The room's list of links is built from
    /// this, so a link is listed there if and only if it was tappable in the conversation — two
    /// answers from one pass of the same matcher, rather than a second opinion that can drift.
    ///
    /// A repeated address is returned once. People paste the same link into a room three times and
    /// a list that says so three times is a list nobody scrolls.
    public static func links(in body: String) -> [URL] {
        guard let linkDetector, !body.isEmpty else { return [] }
        let full = NSRange(body.startIndex..., in: body)

        var seen: Set<URL> = []
        return linkDetector.matches(in: body, options: [], range: full).compactMap { match in
            guard let url = match.url, seen.insert(url).inserted else { return nil }
            return url
        }
    }

    static func applyLinks(to attributed: inout AttributedString, body: String) {
        guard let linkDetector, !body.isEmpty else { return }
        let full = NSRange(body.startIndex..., in: body)
        for match in linkDetector.matches(in: body, options: [], range: full) {
            guard let url = match.url,
                  let stringRange = Range(match.range, in: body),
                  let range = attributedRange(for: stringRange, in: body, attributed: attributed)
            else { continue }
            // Skip anything sitting on top of a mention — the "matrix.org" inside "@alice:matrix.org"
            // is part of a name, not a link the user meant to post.
            if attributed[range].runs.contains(where: { $0.iskra.mentionUserID != nil }) { continue }
            // Or already a link — the sender's own `<a>`, whose words may well be an address that
            // is not where it goes. Theirs wins; the confirmation shows where it really leads.
            if attributed[range].runs.contains(where: { $0.link != nil }) { continue }
            attributed[range].link = url
        }
    }

    // MARK: - Mentions

    static func applyMentions(to attributed: inout AttributedString,
                              body: String,
                              mentionedUserIDs: Set<String>,
                              displayNames: [String: String],
                              ownUserID: String?) {
        guard !mentionedUserIDs.isEmpty, !body.isEmpty else { return }

        for userID in mentionedUserIDs {
            // Both spellings a mention can wear in the plain text: the raw ID, and the "@Name" pill
            // form a client writes when it has a display name to show. The bare display name without
            // the "@" is deliberately *not* matched — a name like "Sam" collides with ordinary words,
            // and a false mention that paints half a sentence is worse than a missed one.
            var tokens = [userID]
            if let name = displayNames[userID], !name.isEmpty {
                tokens.append("@\(name)")
            }

            let isSelf = (userID == ownUserID)
            for token in tokens {
                mark(token: token, in: &attributed, body: body, userID: userID, isSelf: isSelf)
            }
        }
    }

    private static func mark(token: String,
                             in attributed: inout AttributedString,
                             body: String,
                             userID: String,
                             isSelf: Bool) {
        var searchStart = body.startIndex
        while let found = body.range(of: token, range: searchStart..<body.endIndex) {
            if let range = attributedRange(for: found, in: body, attributed: attributed) {
                attributed[range].iskra.mentionUserID = userID
                attributed[range].iskra.mentionIsSelf = isSelf
            }
            searchStart = found.upperBound
        }
    }

    // MARK: - Index mapping

    /// Maps a `String` range onto the same characters inside an `AttributedString` built from that
    /// string. `AttributedString(body)` keeps `body`'s exact character sequence, so a character
    /// distance in one is the same offset in the other — which sidesteps the trap of searching the
    /// attributed string by substring, where a repeated word would match the wrong occurrence.
    static func attributedRange(for stringRange: Range<String.Index>,
                                in body: String,
                                attributed: AttributedString) -> Range<AttributedString.Index>? {
        let lowerOffset = body.distance(from: body.startIndex, to: stringRange.lowerBound)
        let upperOffset = body.distance(from: body.startIndex, to: stringRange.upperBound)
        let characters = attributed.characters
        guard lowerOffset >= 0, upperOffset <= characters.count, lowerOffset <= upperOffset
        else { return nil }
        let lower = characters.index(characters.startIndex, offsetBy: lowerOffset)
        let upper = characters.index(characters.startIndex, offsetBy: upperOffset)
        return lower..<upper
    }
}

// MARK: - Custom attributes

/// The mentioned user's Matrix ID, hung on the run of text that names them.
public enum MentionUserIDAttribute: AttributedStringKey {
    public typealias Value = String
    public static let name = "moscow.swag.iskra.mention.userID"
}

/// Whether the mention on this run is of the signed-in user — the one the bubble paints to catch
/// their eye. A separate flag rather than comparing IDs in the view, so the view never has to know
/// who "you" are.
public enum MentionIsSelfAttribute: AttributedStringKey {
    public typealias Value = Bool
    public static let name = "moscow.swag.iskra.mention.isSelf"
}

public extension AttributeScopes {
    struct IskraScope: AttributeScope {
        public let mentionUserID: MentionUserIDAttribute
        public let mentionIsSelf: MentionIsSelfAttribute
        public let underline: UnderlineAttribute
        public let spoiler: SpoilerAttribute
        public let quote: QuoteAttribute
        public let heading: HeadingAttribute
    }

    var iskra: IskraScope.Type { IskraScope.self }
}

public extension AttributeDynamicLookup {
    subscript<T: AttributedStringKey>(dynamicMember keyPath: KeyPath<AttributeScopes.IskraScope, T>) -> T {
        self[T.self]
    }
}
