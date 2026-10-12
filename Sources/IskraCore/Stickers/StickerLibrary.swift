import Foundation
import Observation

/// Every sticker the account can send, and the two acts that change which those are.
///
/// Three places stickers come from, all of them MSC2545 (see `Sticker`):
///
/// - **the account's own pack**, `im.ponies.user_emotes` in account data. This is "my stickers",
///   the one a sticker is added to from a conversation, and it is the same pack Element and Cinny
///   show — adding one here adds it there.
/// - **packs the account subscribed to**, listed in `im.ponies.emote_rooms` and kept as state in
///   the rooms that publish them.
/// - **the open room's own pack**, if it has one under the empty state key — which is how a
///   community hands its stickers to everybody in it without asking anyone to subscribe.
/// - **the app's own**, "Искорки" (`StickerArt`), so that a sheet opened for the first time has
///   something in it. Drawn on the device, uploaded once per account, and remembered in account
///   data — see `builtInPack()`.
///
/// The account data comes from the SDK, which has it from sync and answers from its store. Room
/// state does not: the FFI has no call for reading one state event, so it is
/// `GET /rooms/{id}/state/im.ponies.room_emotes/{key}` of the app's own, through the same
/// listener as everything else (`UserSession.authorisedSender`).
///
/// Owned by the session and not by a room, because the account's pack and the recent row are the
/// account's: the same in every conversation, and a sticker added in one room is there in the
/// next one at once.
@MainActor
@Observable
public final class StickerLibrary {
    /// What the sheet shows, in the order it shows it: the account's own pack first, then the open
    /// room's, then the subscriptions. Empty packs are left out — a tab with nothing behind it is
    /// a tab somebody presses to find out.
    public private(set) var packs: [StickerPack] = []

    /// The last stickers sent, newest first — the row a sticker sheet opens on.
    public private(set) var recent: [Sticker] = []

    /// True until the first load has answered, so the sheet can tell "nothing yet" from "none".
    public private(set) var isLoading = false
    public private(set) var hasLoaded = false

    /// An add or a remove that the homeserver would not take. The screen says so and clears it.
    public var failure: StickerFailure?

    /// The URLs in the account's own pack — what "already yours" is decided by.
    private var mine: Set<String> = []

    private let readAccountData: @Sendable (String) async throws -> String?
    private let writeAccountData: @Sendable (String, String) async throws -> Void
    private let send: @Sendable (ProxiedRequest) async throws -> ProxiedResponse
    private let upload: (@Sendable (_ mimeType: String, _ data: Data) async throws -> String)?

    /// How many stickers the recent row keeps. Two rows of the sheet on a phone.
    nonisolated static let recentLimit = 16

    /// The account data the recent row lives in. In the account and not on the device, so the
    /// stickers somebody sends on their phone are the first ones offered on their Mac.
    nonisolated static let recentType = "moscow.swag.iskra.recent_stickers"

    /// One answer is waited for this long. A pack in a room on a slow federated server must not
    /// hold the account's own stickers off the screen.
    nonisolated static let timeout: Duration = .seconds(10)

    /// Where the app's own stickers were uploaded to, by shortcode — an MSC2545 pack in shape, so
    /// that it reads like one, but under a type of the app's own: it is not a pack anybody should
    /// find in Element's list of their emoji.
    nonisolated static let builtInType = "moscow.swag.iskra.builtin_stickers"

    /// `upload` is `Client.uploadMedia`. Without it there is no built-in pack: its pictures have
    /// to be on the server before anybody can be sent one.
    init(readAccountData: @escaping @Sendable (String) async throws -> String?,
         writeAccountData: @escaping @Sendable (String, String) async throws -> Void,
         send: @escaping @Sendable (ProxiedRequest) async throws -> ProxiedResponse,
         upload: (@Sendable (_ mimeType: String, _ data: Data) async throws -> String)? = nil) {
        self.readAccountData = readAccountData
        self.writeAccountData = writeAccountData
        self.send = send
        self.upload = upload
    }

    // MARK: - Reading

    /// Reads every pack again, for the room that is open.
    ///
    /// Called each time the sheet opens rather than once per session: a pack is somebody else's
    /// to change, and a sheet that showed this morning's stickers until the app was killed would
    /// be wrong in exactly the way nobody could see.
    public func load(roomID: String?) async {
        isLoading = true
        defer {
            isLoading = false
            hasLoaded = true
        }

        let own = (try? await ownContent()) ?? [:]
        let mine = ImagePack.pack(from: own, origin: .mine)
        self.mine = Set(mine.stickers.map(\.url))

        let subscriptions = ImagePack.subscriptions(in: await object(ofAccountData: ImagePack.subscriptionsType) ?? [:])
        var places = [(roomID: String, stateKey: String)]()
        if let roomID { places.append((roomID, "")) }
        for place in subscriptions where !places.contains(where: { $0 == place }) {
            places.append(place)
        }

        let send = send
        let roomPacks = await withTaskGroup(of: (Int, StickerPack?).self) { group in
            for (index, place) in places.enumerated() {
                group.addTask {
                    (index, await Self.roomPack(roomID: place.roomID, stateKey: place.stateKey, send: send))
                }
            }
            var found = [(Int, StickerPack)]()
            for await (index, pack) in group {
                if let pack { found.append((index, pack)) }
            }
            return found.sorted { $0.0 < $1.0 }.map(\.1)
        }

        packs = ([mine] + roomPacks).filter { !$0.stickers.isEmpty }

        let recentContent = await object(ofAccountData: Self.recentType) ?? [:]
        recent = Self.recent(in: recentContent)

        // Last, and after the others are on screen: the first time, this is a dozen uploads.
        if let builtIn = await builtInPack(), !builtIn.stickers.isEmpty {
            packs.removeAll { $0.isBuiltIn }
            packs.append(builtIn)
        }
    }

    /// Reads the account's own pack, once — what a sticker's menu needs to offer "add" or "remove"
    /// before the sheet has ever been opened. Account data only, from the SDK's store: no room is
    /// asked for anything, so a conversation can call it on opening and cost nobody a request.
    public func prepare() async {
        guard !hasLoaded, !isLoading else { return }
        let own = (try? await ownContent()) ?? [:]
        guard !hasLoaded else { return }
        show(own: own)
    }

    /// Whether this picture is in the account's own pack.
    public func isMine(_ url: String) -> Bool {
        mine.contains(url)
    }

    // MARK: - Changing

    /// Puts a sticker somebody sent into the account's own pack.
    ///
    /// Nothing is uploaded: the picture is already on the homeserver, at a URL anybody in the room
    /// could fetch, and the pack only points at it. That is why the sticker has to be a plain
    /// file — see `Attachment.isPlainMedia`, and `asSticker`, which refuses the other kind.
    public func add(_ sticker: Sticker) async {
        guard !mine.contains(sticker.url) else { return }
        mine.insert(sticker.url)

        do {
            let content = try await ownContent()
            try await writeOwn(ImagePack.adding(sticker, to: content))
        } catch {
            mine.remove(sticker.url)
            Log.media.error("could not add a sticker: \(Log.describe(error), privacy: .public)")
            failure = .add
        }
    }

    /// Takes a sticker back out of the account's own pack.
    public func remove(_ sticker: Sticker) async {
        guard mine.contains(sticker.url) else { return }

        do {
            let content = try await ownContent()
            try await writeOwn(ImagePack.removing(url: sticker.url, from: content))
        } catch {
            Log.media.error("could not remove a sticker: \(Log.describe(error), privacy: .public)")
            failure = .remove
        }
    }

    /// Notes that a sticker was just sent, for the recent row. Its failure is not worth a word to
    /// anybody: the sticker went, and the row is a convenience.
    public func used(_ sticker: Sticker) async {
        recent = Self.pushing(sticker, onto: recent)
        let content: [String: Any] = ["images": recent.map { sticker in
            var image: [String: Any] = ["url": sticker.url, "body": sticker.body]
            if !sticker.info.isEmpty { image["info"] = sticker.info }
            return image
        }]
        try? await write(content, as: Self.recentType)
    }

    nonisolated static func pushing(_ sticker: Sticker, onto recent: [Sticker]) -> [Sticker] {
        Array(([sticker] + recent.filter { $0.url != sticker.url }).prefix(recentLimit))
    }

    nonisolated static func recent(in content: [String: Any]) -> [Sticker] {
        let images = content["images"] as? [[String: Any]] ?? []
        return images.compactMap { ImagePack.sticker(from: $0, shortcode: "") }
    }

    // MARK: - The app's own

    /// The built-in pack, once it has been made this session. A pack that came out empty — no
    /// network, the first time — is not kept, so the next opening of the sheet tries again.
    @ObservationIgnored private var builtIn: Task<StickerPack?, Never>?

    /// The app's own stickers, with the URLs they live at on this account's homeserver.
    ///
    /// The first time an account opens the sheet, each drawing is uploaded — `uploadMedia`, so in
    /// the clear, which is right for a picture every copy of the app draws the same — and where
    /// they went is written to `builtInType`. Every later time, on any of the account's devices,
    /// they are read from there and nothing is uploaded. Whatever fails to upload is simply left
    /// out of the pack and tried again next session.
    private func builtInPack() async -> StickerPack? {
        if let builtIn, let pack = await builtIn.value { return pack }
        let task = Task { await self.makeBuiltInPack() }
        builtIn = task
        let pack = await task.value
        if pack?.stickers.isEmpty ?? true { builtIn = nil }
        return pack
    }

    private func makeBuiltInPack() async -> StickerPack? {
        guard let upload else { return nil }

        let stored = await object(ofAccountData: Self.builtInType) ?? [:]
        let current = stored["version"] as? Int == StickerArt.version
        var images = current ? stored["images"] as? [String: Any] ?? [:] : [:]

        let missing = StickerArt.allCases.filter { (images[$0.rawValue] as? [String: Any])?["url"] == nil }
        if !missing.isEmpty {
            let uploaded = await withTaskGroup(of: (art: StickerArt, url: String, size: Int)?.self) { group in
                for art in missing {
                    group.addTask {
                        let data = art.png()
                        guard !data.isEmpty,
                              let url = try? await withTimeout(Self.timeout, operation: { try await upload("image/png", data) })
                        else { return nil }
                        return (art, url, data.count)
                    }
                }
                var uploaded = [(art: StickerArt, url: String, size: Int)]()
                for await result in group {
                    if let result { uploaded.append(result) }
                }
                return uploaded
            }
            for (art, url, size) in uploaded {
                let info: [String: Any] = ["w": StickerArt.side, "h": StickerArt.side, "mimetype": "image/png", "size": size]
                images[art.rawValue] = ["url": url, "body": art.emoji, "usage": ["sticker"], "info": info]
            }
            if !uploaded.isEmpty {
                try? await write(["version": StickerArt.version,
                                  "pack": ["usage": ["sticker"]],
                                  "images": images],
                                 as: Self.builtInType)
            }
        }

        // In the order they are drawn in, not by shortcode: the happy face first.
        let stickers = StickerArt.allCases.compactMap { art in
            (images[art.rawValue] as? [String: Any]).flatMap { ImagePack.sticker(from: $0, shortcode: art.rawValue) }
        }
        return StickerPack(origin: .builtIn, name: nil, iconURL: nil, stickers: stickers)
    }

    // MARK: - Underneath

    /// The account's pack as this device last wrote it, and when — see `ownContent()`.
    @ObservationIgnored private var written: (content: [String: Any], at: Date)?

    /// How long what was written is trusted over what the SDK says. Long enough for sync to bring
    /// the write back; short enough that a change made on another device afterwards is not hidden
    /// behind it for the rest of the session.
    nonisolated static let writeSettles: TimeInterval = 60

    /// The account's pack, to change.
    ///
    /// The SDK answers account data from its store, and its store learns of a write only when sync
    /// brings it back — a second or so later. Read from there, two stickers added one after the
    /// other would each be added to the pack as it was *before* either, and the second write would
    /// take the first sticker out again. So what this device wrote is the truth until the store
    /// says the same thing, or until it has had a minute to.
    private func ownContent() async throws -> [String: Any] {
        let stored = try await freshObject(ofAccountData: ImagePack.userType)
        guard let written, Date().timeIntervalSince(written.at) < Self.writeSettles else {
            self.written = nil
            return stored
        }
        if NSDictionary(dictionary: stored).isEqual(to: written.content) { self.written = nil }
        return written.content
    }

    /// Writes the account's pack and shows it at once, without waiting for sync to bring it back.
    private func writeOwn(_ content: [String: Any]) async throws {
        try await write(content, as: ImagePack.userType)
        written = (content, Date())
        show(own: content)
    }

    private func show(own content: [String: Any]) {
        let pack = ImagePack.pack(from: content, origin: .mine)
        mine = Set(pack.stickers.map(\.url))
        packs.removeAll { $0.isMine }
        if !pack.stickers.isEmpty { packs.insert(pack, at: 0) }
    }

    /// The account data, or nothing — for reading, where a pack that is not there and a pack that
    /// could not be read are both a pack with no stickers in it.
    private func object(ofAccountData type: String) async -> [String: Any]? {
        try? await freshObject(ofAccountData: type)
    }

    /// The account data as it is now, for changing it. A read that *fails* throws, rather than
    /// answering "empty" — written back, an empty answer would wipe the person's whole pack.
    private func freshObject(ofAccountData type: String) async throws -> [String: Any] {
        let read = readAccountData
        guard let text = try await withTimeout(Self.timeout, operation: { try await read(type) }) else { return [:] }
        guard let data = text.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw StickerFailure.add
        }
        return object
    }

    private func write(_ content: [String: Any], as type: String) async throws {
        let data = try JSONSerialization.data(withJSONObject: content)
        let text = String(bytes: data, encoding: .utf8) ?? "{}"
        let write = writeAccountData
        try await withTimeout(Self.timeout) { try await write(type, text) }
    }

    /// One room's pack, or nil — for a room without one (404), a room this account is not in
    /// (403), and a server that did not answer. None of them is the person's problem.
    nonisolated static func roomPack(roomID: String, stateKey: String,
                                     send: @escaping @Sendable (ProxiedRequest) async throws -> ProxiedResponse) async -> StickerPack? {
        let request = ProxiedRequest(method: "GET",
                                     target: "/_matrix/client/v3/rooms/\(pathSegment(roomID))/state/"
                                         + "\(ImagePack.roomType)/\(pathSegment(stateKey))")
        guard let response = try? await withTimeout(timeout, operation: { try await send(request) }),
              response.status == 200,
              let content = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any] else {
            return nil
        }
        return ImagePack.pack(from: content, origin: .room(roomID: roomID, stateKey: stateKey))
    }

    /// A room ID or a state key, as one segment of a path: `!` and `:` and anything else that is
    /// not plainly safe escaped, and `/` above all — a state key may contain one.
    nonisolated static func pathSegment(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

/// What went wrong changing the account's own pack.
public enum StickerFailure: String, Error, Equatable, Sendable, ActionFailure {
    case add
    case remove

    public var id: String { rawValue }

    public var explanation: LocalizedStringResource {
        switch self {
        case .add: CoreStrings.Stickers.addFailed
        case .remove: CoreStrings.Stickers.removeFailed
        }
    }
}
