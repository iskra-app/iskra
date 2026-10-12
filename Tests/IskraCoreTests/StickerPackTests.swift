import Foundation
import Synchronization
import Testing
import MatrixRustSDK
@testable import IskraCore

/// MSC2545 packs: what counts as a sticker in one, and changing the account's own without
/// losing what other clients keep in it.
@Suite("Sticker packs")
struct StickerPackTests {
    private let cat: [String: Any] = ["url": "mxc://example.org/cat", "body": "😺",
                                      "info": ["w": 256, "h": 256.0, "mimetype": "image/png", "size": 1_234]]

    @Test("an image is a sticker by its own usage, then the pack's, then by saying nothing")
    func usage() {
        let content: [String: Any] = [
            "pack": ["usage": ["emoticon"]],
            "images": [
                "wave": ["url": "mxc://example.org/wave"],                                   // pack: emoji
                "cat": cat.merging(["usage": ["sticker"]]) { $1 },                          // own: sticker
                "both": ["url": "mxc://example.org/both", "usage": ["emoticon", "sticker"]],
                "broken": ["url": "https://example.org/not-mxc", "usage": ["sticker"]],
            ],
        ]
        #expect(ImagePack.stickers(in: content).map(\.shortcode) == ["both", "cat"])

        let unsaid: [String: Any] = ["images": ["wave": ["url": "mxc://example.org/wave"]]]
        #expect(ImagePack.stickers(in: unsaid).map(\.shortcode) == ["wave"])
    }

    @Test("an image's description and size are read, and the description falls back to the shortcode")
    func reading() throws {
        let sticker = try #require(ImagePack.sticker(from: cat, shortcode: "cat"))
        #expect(sticker.body == "😺")
        #expect(sticker.width == 256)
        #expect(sticker.height == 256)
        #expect(sticker.mimeType == "image/png")
        #expect(sticker.size == 1_234)

        let bare = try #require(ImagePack.sticker(from: ["url": "mxc://example.org/x"], shortcode: "hug"))
        #expect(bare.body == "hug")
    }

    @Test("adding keeps every emoji and every unknown field already in the pack")
    func addingKeepsEverything() throws {
        let content: [String: Any] = [
            "pack": ["display_name": "Мои", "usage": ["emoticon"], "com.example.extra": true],
            "images": ["party": ["url": "mxc://example.org/party", "usage": ["emoticon"]]],
        ]
        let sticker = Sticker(url: "mxc://example.org/cat", shortcode: "", body: "Cat hug", width: 256, height: 256)

        let changed = ImagePack.adding(sticker, to: content)
        let pack = try #require(changed["pack"] as? [String: Any])
        #expect(pack["com.example.extra"] as? Bool == true)
        #expect(pack["usage"] as? [String] == ["emoticon"])

        let images = try #require(changed["images"] as? [String: Any])
        #expect(images["party"] != nil)
        let added = try #require(images["cat_hug"] as? [String: Any])
        #expect(added["url"] as? String == "mxc://example.org/cat")
        // Marked on the image, so that the pack's "emoticon" does not make it an emoji.
        #expect(added["usage"] as? [String] == ["sticker"])
        #expect((added["info"] as? [String: Any])?["w"] as? Int == 256)

        #expect(ImagePack.stickers(in: changed).map(\.url) == ["mxc://example.org/cat"])
    }

    @Test("adding a picture already in the pack changes nothing")
    func addingTwice() throws {
        let content: [String: Any] = ["images": ["cat": cat]]
        let again = ImagePack.adding(Sticker(url: "mxc://example.org/cat", shortcode: "", body: "x"), to: content)
        #expect((again["images"] as? [String: Any])?.count == 1)
    }

    @Test("removing takes every entry for the picture and leaves the rest")
    func removing() throws {
        let content: [String: Any] = ["images": ["cat": cat, "cat_2": cat,
                                                 "dog": ["url": "mxc://example.org/dog"]]]
        let changed = ImagePack.removing(url: "mxc://example.org/cat", from: content)
        #expect((changed["images"] as? [String: Any]).map { Set($0.keys) } == ["dog"])
    }

    @Test("a shortcode is the description without spaces or colons, made unique, and 'sticker' for emoji")
    func shortcodes() {
        #expect(ImagePack.shortcode(for: "Cat: hug", taken: []) == "cat_hug")
        #expect(ImagePack.shortcode(for: "😺", taken: []) == "sticker")
        #expect(ImagePack.shortcode(for: "😺", taken: ["sticker", "sticker_2"]) == "sticker_3")
        #expect(ImagePack.shortcode(for: "Привет", taken: []) == "привет")
    }

    @Test("subscriptions are read as one entry per room and state key")
    func subscriptions() {
        let content: [String: Any] = ["rooms": ["!b:x": ["": [:], "cats": [:]], "!a:x": ["": [:]]]]
        let places = ImagePack.subscriptions(in: content).map { "\($0.roomID)/\($0.stateKey)" }
        #expect(places == ["!a:x/", "!b:x/", "!b:x/cats"])
    }

    @Test("the event is the sticker's description, URL and size, and a reply names its event")
    func eventContent() throws {
        let sticker = Sticker(url: "mxc://example.org/cat", shortcode: "cat", body: "😺",
                              width: 256, height: 128, mimeType: "image/png")
        let content = sticker.eventContent(replyingTo: "$event")
        #expect(content["body"] as? String == "😺")
        #expect(content["url"] as? String == "mxc://example.org/cat")
        let info = try #require(content["info"] as? [String: Any])
        #expect(info["w"] as? Int == 256)
        #expect(info["h"] as? Int == 128)
        let reply = (content["m.relates_to"] as? [String: Any])?["m.in_reply_to"] as? [String: Any]
        #expect(reply?["event_id"] as? String == "$event")

        #expect(sticker.eventContent()["m.relates_to"] == nil)
    }

    @Test("only a plain file can go into a pack — an encrypted one's key lives in its event")
    func plainOnly() throws {
        let plain = try #require(Sticker(url: "mxc://example.org/cat", shortcode: "", body: "😺").attachment)
        #expect(plain.isPlainMedia)
        #expect(plain.asSticker?.url == "mxc://example.org/cat")
        #expect(plain.asSticker?.body == "😺")

        let encrypted = try MediaSource.fromJson(json: """
            {"file":{"url":"mxc://example.org/secret","key":{"kty":"oct","key_ops":["encrypt","decrypt"],"alg":"A256CTR",\
            "k":"qcHVMSgYg-71CauWBezXI5qkaRb0LuIy-Wx5kIaHMIA","ext":true},"iv":"X85+XgHN+HEAAAAAAAAAAA",\
            "hashes":{"sha256":"5qG4fFnbbVdlAW/KL4EoIqLWfNbmh0KtV8DY+ZJlcng"},"v":"v2"}}
            """)
        let attachment = Attachment(source: encrypted, thumbnailSource: nil, filename: "sticker", caption: nil,
                                    width: nil, height: nil, duration: nil, mimeType: nil, blurhash: nil)
        #expect(!attachment.isPlainMedia)
        #expect(attachment.asSticker == nil)
    }

    @Test("the recent row puts the newest first, once, and keeps sixteen")
    func recentRow() {
        let stickers = (0..<20).map { Sticker(url: "mxc://x/\($0)", shortcode: "", body: "\($0)") }
        var recent: [Sticker] = []
        for sticker in stickers { recent = StickerLibrary.pushing(sticker, onto: recent) }
        recent = StickerLibrary.pushing(stickers[10], onto: recent)

        #expect(recent.count == StickerLibrary.recentLimit)
        #expect(recent.first?.url == "mxc://x/10")
        #expect(recent.filter { $0.url == "mxc://x/10" }.count == 1)
    }

    @Test("a room ID and a state key are escaped as one path segment each")
    func pathSegments() {
        #expect(StickerLibrary.pathSegment("!abc:example.org") == "%21abc%3Aexample.org")
        #expect(StickerLibrary.pathSegment("a/b c") == "a%2Fb%20c")
        #expect(StickerLibrary.pathSegment("") == "")
    }
}

/// The library over a fake account and a fake server: what the sheet is given, and what an add
/// writes back.
@Suite("Sticker library")
@MainActor
struct StickerLibraryTests {
    final class Account: Sendable {
        let data = Mutex<[String: String]>([:])
        let requests = Mutex<[String]>([])
    }

    private func library(_ account: Account, roomPacks: [String: [String: Any]] = [:]) -> StickerLibrary {
        let packs = roomPacks.mapValues { try! JSONSerialization.data(withJSONObject: $0) }
        return StickerLibrary(
            readAccountData: { type in account.data.withLock { $0[type] } },
            writeAccountData: { type, content in account.data.withLock { $0[type] = content } },
            send: { request in
                account.requests.withLock { $0.append(request.target) }
                if let body = packs[request.target] { return ProxiedResponse(status: 200, body: body) }
                return ProxiedResponse(status: 404, body: Data(#"{"errcode":"M_NOT_FOUND"}"#.utf8))
            })
    }

    private func store(_ object: Any, as type: String, in account: Account) {
        let text = String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        account.data.withLock { $0[type] = text }
    }

    @Test("the account's pack first, then the room's, then subscriptions; empty packs left out")
    func order() async {
        let account = Account()
        store(["images": ["cat": ["url": "mxc://x/cat"]]], as: ImagePack.userType, in: account)
        store(["rooms": ["!sub:x": ["": [:]], "!empty:x": ["": [:]]]], as: ImagePack.subscriptionsType, in: account)

        let roomTarget = "/_matrix/client/v3/rooms/%21here%3Ax/state/im.ponies.room_emotes/"
        let subTarget = "/_matrix/client/v3/rooms/%21sub%3Ax/state/im.ponies.room_emotes/"
        let library = library(account, roomPacks: [
            roomTarget: ["pack": ["display_name": "Здесь"], "images": ["a": ["url": "mxc://x/a"]]],
            subTarget: ["pack": ["display_name": "Подписка"], "images": ["b": ["url": "mxc://x/b"]]],
        ])

        await library.load(roomID: "!here:x")
        #expect(library.packs.map(\.name) == [nil, "Здесь", "Подписка"])
        #expect(library.packs.first?.isMine == true)
        #expect(library.isMine("mxc://x/cat"))
        #expect(!library.isMine("mxc://x/a"))
        #expect(library.hasLoaded)
    }

    @Test("adding writes the sticker into the account's pack, next to what was there")
    func adding() async throws {
        let account = Account()
        store(["images": ["party": ["url": "mxc://x/party", "usage": ["emoticon"]]]],
              as: ImagePack.userType, in: account)
        let library = library(account)
        await library.load(roomID: nil)
        #expect(library.packs.isEmpty)

        await library.add(Sticker(url: "mxc://x/cat", shortcode: "", body: "😺"))
        #expect(library.failure == nil)
        #expect(library.isMine("mxc://x/cat"))
        #expect(library.packs.first?.stickers.map(\.url) == ["mxc://x/cat"])

        let written = try #require(account.data.withLock { $0[ImagePack.userType] })
        let object = try #require(JSONSerialization.jsonObject(with: Data(written.utf8)) as? [String: Any])
        let images = try #require(object["images"] as? [String: Any])
        #expect(Set(images.keys) == ["party", "sticker"])

        await library.remove(Sticker(url: "mxc://x/cat", shortcode: "sticker", body: "😺"))
        #expect(!library.isMine("mxc://x/cat"))
        #expect(library.packs.isEmpty)
    }

    @Test("two adds before sync has brought the first back keep both")
    func addsBeforeSync() async throws {
        // The SDK's store answers with the pack as it was until sync returns the write — here,
        // never — so the second add must build on what the first one wrote, not on the store.
        let written = Account()
        let library = StickerLibrary(
            readAccountData: { _ in nil },
            writeAccountData: { type, content in written.data.withLock { $0[type] = content } },
            send: { _ in ProxiedResponse(status: 404) })

        await library.add(Sticker(url: "mxc://x/a", shortcode: "", body: "a"))
        await library.add(Sticker(url: "mxc://x/b", shortcode: "", body: "b"))
        #expect(library.isMine("mxc://x/a") && library.isMine("mxc://x/b"))

        let text = try #require(written.data.withLock { $0[ImagePack.userType] })
        let object = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(ImagePack.stickers(in: object).map(\.url).sorted() == ["mxc://x/a", "mxc://x/b"])

        // And a reload in the meantime shows them too, rather than the store's empty pack.
        await library.load(roomID: nil)
        #expect(library.packs.first?.stickers.count == 2)
    }

    @Test("a pack that cannot be read is not overwritten by an add")
    func unreadablePackIsNotWiped() async {
        let account = Account()
        let library = StickerLibrary(
            readAccountData: { _ in throw StickerFailure.add },
            writeAccountData: { type, content in account.data.withLock { $0[type] = content } },
            send: { _ in ProxiedResponse(status: 404) })

        await library.add(Sticker(url: "mxc://x/cat", shortcode: "", body: "😺"))
        #expect(library.failure == .add)
        #expect(!library.isMine("mxc://x/cat"))
        #expect(account.data.withLock { $0[ImagePack.userType] } == nil)
    }

    @Test("a sent sticker goes to the front of the recent row, in the account")
    func recent() async {
        let account = Account()
        let library = library(account)
        await library.used(Sticker(url: "mxc://x/a", shortcode: "", body: "a"))
        await library.used(Sticker(url: "mxc://x/b", shortcode: "", body: "b"))
        #expect(library.recent.map(\.url) == ["mxc://x/b", "mxc://x/a"])

        let reread = self.library(account)
        await reread.load(roomID: nil)
        #expect(reread.recent.map(\.url) == ["mxc://x/b", "mxc://x/a"])
    }
}
