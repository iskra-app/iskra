import Foundation
import MatrixRustSDK

/// One sticker that can be sent: a picture already on the homeserver, and what to call it.
///
/// Matrix has no sticker *store*. What it has is MSC2545, the image-pack format Element, Cinny,
/// FluffyChat and Nheko all read: a pack is a JSON object of pictures by shortcode, kept either
/// in the account's own data (`im.ponies.user_emotes` — "my stickers") or as a room's state
/// (`im.ponies.room_emotes`), which other accounts subscribe to by listing the room in
/// `im.ponies.emote_rooms`. A sticker is therefore nothing but an `mxc://` URL with a description
/// and a size, and sending one is pointing at that URL from an `m.sticker` event.
///
/// Which is also why a pack's picture is *not* encrypted, and cannot be: it is one file read by
/// everybody the pack is shared with, in every room it is sent to, and there is no key to give
/// them. A sticker sent into an encrypted room is encrypted as an event — what it says and who
/// sent it — and points at a picture that is as public as the pack it came from.
public struct Sticker: Identifiable, Sendable, Equatable, Hashable {
    /// The `mxc://` URL — the one thing two stickers can be told apart by. The same picture in
    /// two packs is the same sticker.
    public var id: String { url }

    public let url: String

    /// The pack's name for it, unique within its pack: `hug`, `cat_lol`.
    public let shortcode: String

    /// The words that stand in for the picture — what the event's `body` says, what VoiceOver
    /// reads, and what a client that cannot draw stickers shows instead. Usually an emoji.
    public let body: String

    public let width: Int?
    public let height: Int?
    public let mimeType: String?
    public let size: Int?

    public init(url: String, shortcode: String, body: String,
                width: Int? = nil, height: Int? = nil, mimeType: String? = nil, size: Int? = nil) {
        self.url = url
        self.shortcode = shortcode
        self.body = body
        self.width = width
        self.height = height
        self.mimeType = mimeType
        self.size = size
    }

    /// The picture, in the shape every view that draws media already takes. Nil only for a URL
    /// the SDK refuses to read as one, which a pack written by hand can contain.
    public var attachment: Attachment? {
        guard let source = try? MediaSource.fromUrl(url: url) else { return nil }
        return Attachment(source: source,
                          thumbnailSource: nil,
                          filename: "sticker",
                          caption: body.isEmpty ? nil : body,
                          width: width,
                          height: height,
                          duration: nil,
                          mimeType: mimeType,
                          blurhash: nil)
    }

    /// The `info` block, as both the pack and the `m.sticker` event spell it.
    var info: [String: Any] {
        var info: [String: Any] = [:]
        if let width { info["w"] = width }
        if let height { info["h"] = height }
        if let mimeType { info["mimetype"] = mimeType }
        if let size { info["size"] = size }
        return info
    }

    /// The content of the `m.sticker` event that sends it.
    ///
    /// `info` is sent even when it is empty, because the spec says it is required — and because
    /// Element draws a sticker with no `w`/`h` at a size of its own choosing, while every client
    /// draws one with them at the size it was made.
    func eventContent(replyingTo eventID: String? = nil) -> [String: Any] {
        var content: [String: Any] = ["body": body, "url": url, "info": info]
        if let eventID {
            content["m.relates_to"] = ["m.in_reply_to": ["event_id": eventID]]
        }
        return content
    }
}

/// A set of stickers with a name: the account's own, or one a room publishes.
public struct StickerPack: Identifiable, Sendable, Equatable {
    public enum Origin: Sendable, Equatable, Hashable {
        /// `im.ponies.user_emotes` — the account's own, which is the one stickers are added to.
        case mine
        /// `im.ponies.room_emotes` with this state key, in this room.
        case room(roomID: String, stateKey: String)
        /// The app's own — see `StickerArt`. Uploaded by this account and read by nobody else.
        case builtIn
    }

    public let origin: Origin

    public var id: String {
        switch origin {
        case .mine: "mine"
        case let .room(roomID, stateKey): "\(roomID)/\(stateKey)"
        case .builtIn: "builtin"
        }
    }

    /// What the pack calls itself, if it says. The account's own pack usually does not, and the
    /// screen names it.
    public let name: String?

    /// The picture on the pack's tab: its own avatar when it has one, else its first sticker.
    public let iconURL: String?

    public let stickers: [Sticker]

    public var isMine: Bool { origin == .mine }

    public var isBuiltIn: Bool { origin == .builtIn }

    public init(origin: Origin, name: String?, iconURL: String?, stickers: [Sticker]) {
        self.origin = origin
        self.name = name
        self.iconURL = iconURL
        self.stickers = stickers
    }

    /// The tab's picture, in the shape a view can draw.
    public var icon: Sticker? {
        if let iconURL { return Sticker(url: iconURL, shortcode: "", body: name ?? "") }
        return stickers.first
    }
}

/// The MSC2545 format itself: reading a pack, and changing one without losing what is in it.
///
/// Changes are made on the *raw* JSON and never on a parsed copy, and that is the one rule in
/// here that matters. The account's own pack is shared with every other client the person uses,
/// and most of what is in it is not stickers: it is custom emoji (`usage: ["emoticon"]`), and
/// fields this app has never heard of. A pack parsed into `[Sticker]` and written back would
/// quietly delete all of that from every device the account is signed in on.
enum ImagePack {
    static let userType = "im.ponies.user_emotes"
    static let roomType = "im.ponies.room_emotes"
    static let subscriptionsType = "im.ponies.emote_rooms"

    typealias JSON = [String: Any]

    /// The stickers in a pack's content — what is marked for use as a sticker, explicitly or by
    /// saying nothing at all.
    ///
    /// An image's own `usage` wins over the pack's; a pack that says neither is both, per the
    /// MSC. Ordered by shortcode: JSON objects have no order, and a pack that came back in a new
    /// shuffle every time it was opened would put every sticker somewhere new.
    static func stickers(in content: JSON) -> [Sticker] {
        let packUsage = (content["pack"] as? JSON)?["usage"] as? [String]
        let images = content["images"] as? JSON ?? [:]

        return images.compactMap { shortcode, value -> Sticker? in
            guard let image = value as? JSON else { return nil }
            let usage = image["usage"] as? [String] ?? packUsage
            guard usage?.contains("sticker") ?? true else { return nil }
            return sticker(from: image, shortcode: shortcode)
        }
        .sorted { $0.shortcode.localizedStandardCompare($1.shortcode) == .orderedAscending }
    }

    /// One image entry. The MSC's `body` defaults to the shortcode, and so does this.
    static func sticker(from image: JSON, shortcode: String) -> Sticker? {
        guard let url = image["url"] as? String, url.hasPrefix("mxc://") else { return nil }
        let info = image["info"] as? JSON ?? [:]
        let body = (image["body"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? shortcode
        return Sticker(url: url,
                       shortcode: shortcode,
                       body: body,
                       width: integer(info["w"]),
                       height: integer(info["h"]),
                       mimeType: info["mimetype"] as? String,
                       size: integer(info["size"]))
    }

    static func pack(from content: JSON, origin: StickerPack.Origin) -> StickerPack {
        let pack = content["pack"] as? JSON
        let name = (pack?["display_name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let icon = (pack?["avatar_url"] as? String).flatMap { $0.hasPrefix("mxc://") ? $0 : nil }
        return StickerPack(origin: origin, name: name, iconURL: icon, stickers: stickers(in: content))
    }

    /// The account's pack with this sticker in it — and with everything that was already there.
    ///
    /// The image is marked `["sticker"]` on its own, so that a pack whose *pack* usage says
    /// "emoticon" does not turn the new sticker into an emoji in Element's composer.
    static func adding(_ sticker: Sticker, to content: JSON) -> JSON {
        var content = content
        var images = content["images"] as? JSON ?? [:]

        let alreadyThere = images.values.contains { ($0 as? JSON)?["url"] as? String == sticker.url }
        guard !alreadyThere else { return content }

        let code = shortcode(for: sticker.body, taken: Set(images.keys))
        var image: JSON = ["url": sticker.url, "usage": ["sticker"]]
        if !sticker.body.isEmpty { image["body"] = sticker.body }
        if !sticker.info.isEmpty { image["info"] = sticker.info }
        images[code] = image

        content["images"] = images
        return content
    }

    /// The account's pack without this picture. Every entry pointing at it goes — the same
    /// picture under two shortcodes is still the one sticker the person asked to remove.
    static func removing(url: String, from content: JSON) -> JSON {
        var content = content
        guard var images = content["images"] as? JSON else { return content }
        images = images.filter { ($0.value as? JSON)?["url"] as? String != url }
        content["images"] = images
        return content
    }

    /// A shortcode for a sticker that arrived with only a description.
    ///
    /// The MSC forbids spaces and colons in one — it is written as `:code:` in a composer — so
    /// what is kept is letters, digits, `-` and `_`. A description that is all emoji, which is
    /// most of them, keeps nothing and becomes `sticker`. Then a number, until it is free.
    static func shortcode(for body: String, taken: Set<String>) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let kept = body.lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .unicodeScalars
            .filter { allowed.contains($0) }
        let base = String(String.UnicodeScalarView(kept)).prefix(32)
        let stem = base.isEmpty ? "sticker" : String(base)

        guard taken.contains(stem) else { return stem }
        var number = 2
        while taken.contains("\(stem)_\(number)") { number += 1 }
        return "\(stem)_\(number)"
    }

    /// The rooms whose packs the account has subscribed to, with the state key of each pack —
    /// `{"rooms": {"!room": {"state_key": {}}}}`.
    static func subscriptions(in content: JSON) -> [(roomID: String, stateKey: String)] {
        let rooms = content["rooms"] as? JSON ?? [:]
        return rooms.flatMap { roomID, keys -> [(roomID: String, stateKey: String)] in
            ((keys as? JSON) ?? [:]).keys.map { (roomID: roomID, stateKey: $0) }
        }
        .sorted { ($0.roomID, $0.stateKey) < ($1.roomID, $1.stateKey) }
    }

    /// JSON numbers arrive as `Int` from one decoder and `Double` from another, and a size
    /// written by a client in JavaScript is very often `512.0`.
    private static func integer(_ value: Any?) -> Int? {
        switch value {
        case let value as Int: value
        case let value as Double where value.isFinite: Int(value)
        case let value as NSNumber: value.intValue
        default: nil
        }
    }
}

extension Attachment {
    /// Whether these bytes are a plain `mxc://` file anybody with the URL can fetch — which is
    /// the only kind of picture a pack can hold.
    ///
    /// A sticker that arrived as an *encrypted* file (`file` and not `url` in its event) points
    /// at ciphertext whose key travelled inside that one event. Putting its URL in a pack would
    /// make a sticker nobody — this account included, on the next device — could ever draw.
    var isPlainMedia: Bool {
        guard let data = source.toJson().data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return false
        }
        // `{"url": "mxc://…"}` for a plain file, `{"file": {…, "key": …}}` for an encrypted one.
        guard let object = json as? [String: Any] else { return false }
        return object["file"] == nil && object["url"] is String
    }

    /// The sticker this attachment is, for adding it to a pack: the same picture, described the
    /// same way, at the same size. Nil for anything a pack could not hold — see `isPlainMedia`.
    public var asSticker: Sticker? {
        guard isPlainMedia else { return nil }
        let url = source.url()
        guard url.hasPrefix("mxc://") else { return nil }
        let body = caption ?? ""
        return Sticker(url: url,
                       shortcode: "",
                       body: body,
                       width: width,
                       height: height,
                       mimeType: mimeType,
                       size: nil)
    }
}
