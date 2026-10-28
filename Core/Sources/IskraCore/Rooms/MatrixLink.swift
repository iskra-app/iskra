import Foundation

/// A pointer at a person or a room, in whichever of its spellings it arrived.
///
/// **What is written out is always an `s.iskra.wtf` link** — in a QR code, behind "Share". It is
/// a plain web address, so the iPhone's camera opens it with nothing installed; the page there says
/// whose it is and offers Iskra, or any other Matrix client, to open it in. With Iskra installed the
/// domain is ours to claim (Associated Domains, `Apps/project.yml`), so the camera hands it straight
/// to the app. `matrix.to` did the same job before, but it is not ours: its links can never open
/// in this app directly, and its page offers every client but this one. `matrix:` is the protocol's
/// own URI scheme and the better-designed of the two, but a camera that meets it with no app
/// installed to answer it shows nothing.
///
/// **What is read is everything** — `s.iskra.wtf` and `matrix.to`, with or without `?via=`,
/// `matrix:u/…`, `matrix:r/…`, `matrix:roomid/…`, the same three after `wtf.iskra://` (the button
/// on the `s.iskra.wtf` page), and a bare `@person:server`, `#room:server` or `!id` — because a QR
/// code or a link from somewhere else was made by somebody else's app, and is whatever that app
/// chose.
public enum MatrixLink: Sendable, Hashable {
    /// A person, by Matrix ID.
    case user(String)
    /// A room, by alias (`#name:server`) or ID (`!id`), with the servers to ask through when this
    /// account's own server is not in it yet.
    case room(String, via: [String])

    /// The `s.iskra.wtf` link — see the note on the type for why this spelling and not another.
    /// `/@boris:matrix.org`, `/%23iskra:matrix.org`, `/!abc:matrix.org?via=matrix.org`.
    public var url: URL {
        let (target, via) = parts
        // The ID goes in the path, where `#` would end it and start a fragment, so it is escaped;
        // `:` and `@` and `!` are fine as they are.
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "#?&/;")
        var path = target.addingPercentEncoding(withAllowedCharacters: allowed) ?? target
        path += Self.query(via)
        // Force-unwrapped because every part of it was escaped above; a link that would not parse
        // here is a bug in this function, not a property of the input.
        return URL(string: "https://\(Self.webHost)/\(path)")!
    }

    /// The same pointer as a link straight into this app — `wtf.iskra://u/boris:matrix.org`,
    /// `wtf.iskra://r/iskra:matrix.org`, `wtf.iskra://roomid/abc:matrix.org?via=…` — which is
    /// what the "Open in Iskra" button on the `s.iskra.wtf` page opens. MSC2312's names for the
    /// sigils, as in `matrix:`, so that the two read the same way.
    public var deepLink: URL {
        let (target, via) = parts
        let kind: String
        switch target.first {
        case "@": kind = "u"
        case "#": kind = "r"
        default: kind = "roomid"
        }
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "#?&/;")
        let id = String(target.dropFirst())
        let path = (id.addingPercentEncoding(withAllowedCharacters: allowed) ?? id) + Self.query(via)
        return URL(string: "wtf.iskra://\(kind)/\(path)")!
    }

    /// The host of the link page, which is the one web address this app reads as its own.
    public static let webHost = "s.iskra.wtf"

    private var parts: (target: String, via: [String]) {
        switch self {
        case .user(let userID): (userID, [])
        case .room(let room, let servers): (room, servers)
        }
    }

    private static func query(_ via: [String]) -> String {
        guard !via.isEmpty else { return "" }
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=#")
        return "?" + via.map { "via=\($0.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0)" }
            .joined(separator: "&")
    }

    /// Reads a link, a URI or a bare identifier. Nil for anything that is not one — a QR code on a
    /// menu, a Wi-Fi password, a link to somewhere else entirely.
    public init?(parsing text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() {
            switch scheme {
            case "https", "http":
                switch url.host?.lowercased() {
                case "matrix.to":
                    guard let fragment = url.fragment(percentEncoded: false) else { return nil }
                    // `#/@boris:matrix.org` — the fragment, less its leading slash, is the
                    // identifier, optionally followed by an event ID and a query.
                    let path = fragment.hasPrefix("/") ? String(fragment.dropFirst()) : fragment
                    self.init(identifier: path)
                case Self.webHost:
                    self.init(webLink: url)
                default:
                    return nil
                }
                return
            case "matrix":
                self.init(msc2312: String(trimmed.dropFirst("matrix:".count)))
                return
            case "wtf.iskra":
                // The app's own scheme carries other things too — the sign-in callback, the share
                // sheet's hand-over, a Live Activity's `wtf.iskra:/open?room=…` — and all of
                // those are written without a host. A link to a person or a room is the one with
                // `//` and one of MSC2312's three words after it; anything else is not this type's.
                let prefix = "wtf.iskra://"
                guard trimmed.lowercased().hasPrefix(prefix) else { return nil }
                self.init(msc2312: String(trimmed.dropFirst(prefix.count)))
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

    /// `https://s.iskra.wtf/@boris:matrix.org`, `/%23iskra:matrix.org`, `/!abc:matrix.org?via=…`
    /// — the ID in the path, as `url` writes it. The page also answers to the ID in the fragment,
    /// so that a `matrix.to` link with its host swapped works: `/#/@boris:matrix.org` like
    /// `matrix.to`, and `/#iskra:matrix.org`, where the `#` that starts the fragment is the alias's
    /// own.
    private init?(webLink url: URL) {
        let path = url.path(percentEncoded: false)
        if path.count > 1 {
            let query = url.query(percentEncoded: true).map { "?" + $0 } ?? ""
            self.init(identifier: String(path.dropFirst()) + query)
            return
        }
        guard let fragment = url.fragment(percentEncoded: false), !fragment.isEmpty else { return nil }
        if fragment.hasPrefix("/") {
            self.init(identifier: String(fragment.dropFirst()))
        } else if let sigil = fragment.first, "@#!".contains(sigil) {
            self.init(identifier: fragment)
        } else {
            self.init(identifier: "#" + fragment)
        }
    }

    /// `u/boris:matrix.org`, `r/room:matrix.org`, `roomid/abc:matrix.org?via=…` — MSC2312, the
    /// spec's own scheme, after `matrix:` or `wtf.iskra://`. The sigil is spelled out as a word.
    private init?(msc2312 body: String) {
        let (path, query) = Self.split(body, at: "?")
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
