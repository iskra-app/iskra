import Foundation

/// A pointer at a person or a room, in whichever of its spellings it arrived.
///
/// **What is written out is always a `matrix.to` link** — in a QR code, behind "Share". It is the
/// one spelling everything understands: the iPhone's camera opens it as a web page, every Matrix
/// client recognises it as a person or a room, and somebody without a Matrix client at all lands on
/// a page that says whose it is and offers them one. `matrix:` is the protocol's own URI scheme and
/// the better-designed of the two, but a camera that meets it with no app installed to answer it
/// shows nothing; and an `iskra://` link would be a format of this app's own that only this app
/// could ever read.
///
/// **What is read is everything** — `matrix.to` with or without `?via=`, `matrix:u/…`, `matrix:r/…`,
/// `matrix:roomid/…`, and a bare `@person:server`, `#room:server` or `!id` — because a QR code or a
/// link from somewhere else was made by somebody else's app, and is whatever that app chose.
public enum MatrixLink: Sendable, Hashable {
    /// A person, by Matrix ID.
    case user(String)
    /// A room, by alias (`#name:server`) or ID (`!id`), with the servers to ask through when this
    /// account's own server is not in it yet.
    case room(String, via: [String])

    /// The `matrix.to` link — see the note on the type for why this spelling and not another.
    public var url: URL {
        var target: String
        var via: [String] = []
        switch self {
        case .user(let userID): target = userID
        case .room(let room, let servers): target = room; via = servers
        }
        // The fragment carries the ID, and `#` in an alias must be escaped there or it would end
        // the fragment before it began. `:` and `@` and `!` are fine as they are.
        var allowed = CharacterSet.urlFragmentAllowed
        allowed.remove(charactersIn: "#?&/")
        target = target.addingPercentEncoding(withAllowedCharacters: allowed) ?? target
        if !via.isEmpty {
            target += "?" + via.map { "via=\($0)" }.joined(separator: "&")
        }
        // Force-unwrapped because every part of it was escaped above; a link that would not parse
        // here is a bug in this function, not a property of the input.
        return URL(string: "https://matrix.to/#/\(target)")!
    }

    /// Reads a link, a URI or a bare identifier. Nil for anything that is not one — a QR code on a
    /// menu, a Wi-Fi password, a link to somewhere else entirely.
    public init?(parsing text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() {
            switch scheme {
            case "https", "http":
                guard url.host?.lowercased() == "matrix.to", let fragment = url.fragment(percentEncoded: false) else { return nil }
                // `#/@boris:matrix.org` — the fragment, less its leading slash, is the identifier,
                // optionally followed by an event ID and a query.
                let path = fragment.hasPrefix("/") ? String(fragment.dropFirst()) : fragment
                self.init(identifier: path)
                return
            case "matrix":
                self.init(matrixURI: trimmed)
                return
            default:
                break
            }
        }

        self.init(identifier: trimmed)
    }

    /// `@x:y`, `#x:y`, `!x[:y]`, optionally followed by `/event` and `?via=…`.
    private init?(identifier: String) {
        let (head, query) = Self.split(identifier, at: "?")
        // `/$event` after a room is a pointer at one message; the room is where it lives, and
        // the room is what is opened.
        let id = String(head.split(separator: "/", maxSplits: 1).first ?? "")
        guard let sigil = id.first else { return nil }

        switch sigil {
        case "@":
            guard Self.isMatrixUserID(id) else { return nil }
            self = .user(id)
        case "#", "!":
            guard UserSession.isRoomAddress(id) else { return nil }
            self = .room(id, via: Self.via(in: query))
        default:
            return nil
        }
    }

    /// `matrix:u/boris:matrix.org`, `matrix:r/room:matrix.org`, `matrix:roomid/abc:matrix.org?via=…`
    /// — MSC2312, the spec's own scheme. The sigil is spelled out as a word, and there is no `//`.
    private init?(matrixURI: String) {
        let body = matrixURI.dropFirst("matrix:".count)
        let (path, query) = Self.split(String(body), at: "?")
        let parts = path.split(separator: "/").map { $0.removingPercentEncoding ?? String($0) }
        guard parts.count >= 2 else { return nil }

        switch parts[0] {
        case "u":
            let id = "@" + parts[1]
            guard Self.isMatrixUserID(id) else { return nil }
            self = .user(id)
        case "r":
            let id = "#" + parts[1]
            guard UserSession.isRoomAddress(id) else { return nil }
            self = .room(id, via: Self.via(in: query))
        case "roomid":
            let id = "!" + parts[1]
            guard UserSession.isRoomAddress(id) else { return nil }
            self = .room(id, via: Self.via(in: query))
        default:
            return nil
        }
    }

    private static func split(_ text: String, at separator: Character) -> (String, String?) {
        guard let index = text.firstIndex(of: separator) else { return (text, nil) }
        return (String(text[..<index]), String(text[text.index(after: index)...]))
    }

    private static func via(in query: String?) -> [String] {
        guard let query else { return [] }
        return query.split(separator: "&").compactMap { pair in
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, parts[0] == "via" else { return nil }
            return parts[1].removingPercentEncoding ?? String(parts[1])
        }
    }

    private static func isMatrixUserID(_ text: String) -> Bool {
        RoomDetailsStore.isMatrixID(text) && !text.contains(" ")
    }
}
