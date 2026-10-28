import CryptoKit
import Foundation
import Observation

/// Real pictures for the places that have no session to fetch them with — the share sheet and the
/// home-screen widget.
///
/// Both draw from `ChatDirectory`, and until this existed both drew the creature from
/// `avatarSeed` for everybody, not because the person had no picture but because there was nowhere
/// to get it from: downloading takes the account's token, and neither process holds one (the share
/// extension is not even granted the Keychain group). So the app, which has the token, puts the
/// pictures where the other two can read them — a file per picture in the App Group's `Faces`
/// folder — and names the file in the chat's directory entry (`ChatDirectoryEntry.faceFile`).
///
/// **The file is named after the `mxc://` address**, hashed. A new picture is a new address, so it
/// is a new file and nothing ever has to be invalidated; the old one is simply no longer named by
/// any entry and is swept up at the next launch (`sweep`).
///
/// **Not every chat.** Pinned ones, the ones chosen in widgets, and the first few dozen of the list
/// — the ones the share sheet shows before anybody scrolls (`wanted`). The rest keep the creature
/// until they get there.
///
/// Privacy: a Matrix avatar is public by construction — the server hands it to anybody without
/// encryption — and *who the user talks to* is already in the same container, as names. This puts
/// new bytes in the same place, not a new fact in a new one.
public enum DirectoryFaces {
    /// Where the pictures are. Kept out of backups — they are a cache of somebody else's pictures —
    /// and readable after the first unlock, because a widget is drawn on a locked phone and a file
    /// under `.complete` would be a widget of empty circles until the phone is opened.
    public static func folder(environment: AppEnvironment = .default) throws -> URL {
        var folder = try environment.containerURL().appending(component: "Faces", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
        return folder
    }

    /// The file a picture goes into: its address, hashed. The address itself is not a usable file
    /// name — it has slashes and a colon in it, and it is the server's to choose.
    public static func fileName(for avatarURL: String) -> String {
        let digest = SHA256.hash(data: Data(avatarURL.utf8))
        return digest.map { String(format: "%02x", $0) }.joined() + ".jpg"
    }

    /// Where a named face is, or nil for a name that is not a plain file name — the name comes out
    /// of the shared defaults, which another process writes.
    public static func url(of name: String?, in folder: URL) -> URL? {
        guard let name, SafeFilename.isSafe(name) else { return nil }
        return folder.appending(component: name)
    }

    /// The face for an entry, if it has one and it is on the disk.
    public static func url(for entry: ChatDirectoryEntry, in folder: URL?) -> URL? {
        guard let folder, let url = url(of: entry.faceFile, in: folder),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    static func remove(_ names: some Sequence<String>, in folder: URL) {
        for name in names {
            if let url = url(of: name, in: folder) { try? FileManager.default.removeItem(at: url) }
        }
    }

    /// Takes away every picture no entry in the directory names any more — a picture that was
    /// changed, a chat that was left, a chat that fell far enough down the list. Called at launch,
    /// beside `ChatDirectory.sweepOutbox`, when nothing is being downloaded.
    public static func sweep(in folder: URL? = try? DirectoryFaces.folder(), defaults: UserDefaults? = ChatDirectory.sharedDefaults) {
        guard let folder else { return }
        let named = Set(ChatDirectory.directory(from: defaults).compactMap(\.faceFile))
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        remove(files.filter { !named.contains($0) }, in: folder)
    }

    /// One chat as far as choosing pictures goes.
    public struct Candidate: Sendable, Equatable {
        public let entityID: String
        public let avatarURL: String?
        public let isPinned: Bool

        public init(entityID: String, avatarURL: String?, isPinned: Bool) {
            self.entityID = entityID
            self.avatarURL = avatarURL
            self.isPinned = isPinned
        }
    }

    /// The pictures worth having on the disk, most wanted first: pinned chats (the widget's default
    /// row), then the ones chosen in a widget, then the top of the list in its own order. Each
    /// address once, however many chats share it.
    public static func wanted(_ chats: [Candidate], chosen: Set<String>, recent: Int = recentCount) -> [String] {
        var order: [String] = []
        var seen: Set<String> = []
        func take(_ chat: Candidate) {
            guard let url = chat.avatarURL, !url.isEmpty, seen.insert(url).inserted else { return }
            order.append(url)
        }
        chats.filter(\.isPinned).forEach(take)
        chats.filter { chosen.contains($0.entityID) }.forEach(take)
        chats.prefix(recent).forEach(take)
        return order
    }

    /// How far down the list pictures are fetched: the share sheet's first screens and a little more.
    public static let recentCount = 40

    /// What is fetched: the server's own thumbnail at this size, which covers a widget's faces at
    /// 3× and the share sheet's grid, and is a few kilobytes.
    public static let pixelSize = 192

    /// Nothing sane is larger, and the server can send anything it likes.
    static let byteLimit = 2 * 1024 * 1024
}

/// Fetches the pictures `DirectoryFaces.wanted` names that are not on the disk yet — in the app,
/// which has the token.
///
/// Quietly and at the back of the queue: three at a time, at utility priority, and only after the
/// room list has been still for a moment, because initial sync rewrites the list dozens of times
/// in its first seconds and a download per rewrite is how the chat list stutters. A picture that
/// would not come is not asked for again in this launch.
///
/// `revision` goes up when new pictures have landed, which is the root's cue to write the
/// directory again so the entries name them.
@MainActor
@Observable
public final class ChatFaces {
    public private(set) var revision = 0

    @ObservationIgnored private let fetch: @Sendable (String) async throws -> Data
    @ObservationIgnored private let folder: () -> URL?
    @ObservationIgnored private var pending: [String] = []
    @ObservationIgnored private var running: Task<Void, Never>?
    @ObservationIgnored private var refused: Set<String> = []

    /// - Parameter fetch: the bytes behind an `mxc://` address — `MediaLoader.avatar` in the app.
    public init(folder: @escaping () -> URL? = { try? DirectoryFaces.folder() },
                fetch: @escaping @Sendable (String) async throws -> Data) {
        self.folder = folder
        self.fetch = fetch
    }

    /// The file a picture is in, if it has been fetched.
    public func file(for avatarURL: String?) -> String? {
        guard let avatarURL, !avatarURL.isEmpty, let folder = folder() else { return nil }
        let name = DirectoryFaces.fileName(for: avatarURL)
        return FileManager.default.fileExists(atPath: folder.appending(component: name).path) ? name : nil
    }

    /// Asks for these pictures, in this order. Replaces whatever was asked for before and has not
    /// started, so the latest room list always wins.
    public func want(_ urls: [String], settle: Duration = .seconds(2)) {
        pending = urls.filter { file(for: $0) == nil && !refused.contains($0) }
        guard running == nil, !pending.isEmpty else { return }
        running = Task(priority: .utility) { [weak self] in
            try? await Task.sleep(for: settle)
            await self?.drain()
        }
    }

    /// Waits for whatever is being fetched. For tests.
    func settled() async {
        while let running { await running.value }
    }

    private func drain() async {
        defer { running = nil }
        guard let folder = folder() else { return }
        var landed = false
        while !pending.isEmpty, !Task.isCancelled {
            let batch = Array(pending.prefix(Self.atOnce))
            pending.removeFirst(batch.count)
            let fetch = fetch
            let results = await withTaskGroup(of: (String, Data?).self) { group in
                for url in batch {
                    group.addTask(priority: .utility) {
                        let data = try? await withTimeout(.seconds(15)) { try await fetch(url) }
                        return (url, data)
                    }
                }
                var all: [(String, Data?)] = []
                for await result in group { all.append(result) }
                return all
            }
            for (url, data) in results {
                guard let data, !data.isEmpty, data.count <= DirectoryFaces.byteLimit else {
                    refused.insert(url)
                    continue
                }
                let target = folder.appending(component: DirectoryFaces.fileName(for: url))
                do {
                    try data.write(to: target, options: Self.writing)
                    landed = true
                } catch {
                    refused.insert(url)
                    Log.media.error("a chat picture could not be kept: \(Log.describe(error), privacy: .public)")
                }
            }
        }
        if landed { revision += 1 }
    }

    private static let atOnce = 3

    #if os(iOS)
    private static let writing: Data.WritingOptions = [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
    #else
    private static let writing: Data.WritingOptions = [.atomic]
    #endif
}

/// What the favourites widget shows and when it has to be told to look again — decided here, where
/// it can be tested, and used by both the widget and the app.
public enum WidgetChats {
    /// The chats in a widget of `count` faces: those chosen in it, in the order chosen, or — with
    /// nothing chosen — the account's pinned chats and then the top of its list.
    ///
    /// A chosen chat that has gone from the directory (left, or its account signed out) leaves its
    /// place to the next one rather than to a hole.
    public static func fill(_ entries: [ChatDirectoryEntry], chosen: [String], count: Int,
                            account: String? = nil) -> [ChatDirectoryEntry] {
        var picked: [ChatDirectoryEntry] = []
        var seen: Set<String> = []
        func take(_ entry: ChatDirectoryEntry) {
            guard picked.count < count, seen.insert(entry.entityID).inserted else { return }
            picked.append(entry)
        }
        for id in chosen {
            if let entry = entries.first(where: { $0.entityID == id }) ?? entries.first(where: { $0.id == id }) {
                take(entry)
            }
        }
        guard chosen.isEmpty else { return picked }

        let own = account.map { id in entries.filter { $0.accountID == id } }.flatMap { $0.isEmpty ? nil : $0 } ?? entries
        own.filter { $0.isPinned == true }.forEach(take)
        own.forEach(take)
        return picked
    }

    /// Everything a widget draws, as one string: a change in it is a reason to redraw, and nothing
    /// else is. Without this every sync tick would reload the widget and spend WidgetKit's daily
    /// budget by breakfast.
    public static func fingerprint(_ entries: [ChatDirectoryEntry], chosen: [String],
                                   account: String?, locked: Bool) -> String {
        let shown = fill(entries, chosen: [], count: largest, account: account)
            + entries.filter { chosen.contains($0.entityID) }
        let faces = shown.map { "\($0.entityID)\u{1F}\($0.name)\u{1F}\($0.faceFile ?? "")\u{1F}\(($0.unreadCount ?? 0) > 0)" }
        return ([locked ? "locked" : "open"] + faces).joined(separator: "\u{1E}")
    }

    /// The favourites widget's `kind` — what the app names when it asks WidgetKit to redraw it.
    public static let kind = "wtf.iskra.favourites"

    /// The most faces any widget size shows.
    public static let largest = 8

    private static let chosenKey = "widgets.chosenChats"

    /// The chats somebody picked in a widget, said by the widget each time it draws — so that the
    /// app, which cannot see a widget's configuration, knows whose pictures to fetch. Dated, so a
    /// widget taken off the home screen stops counting after a while.
    public static func recordChosen(_ ids: [String], in defaults: UserDefaults? = ChatDirectory.sharedDefaults,
                                    now: Date = .now) {
        guard !ids.isEmpty else { return }
        var all = chosenDates(in: defaults)
        for id in ids { all[id] = now.timeIntervalSinceReferenceDate }
        defaults?.set(all, forKey: chosenKey)
    }

    /// Every chat chosen in any widget in the last month.
    public static func chosen(in defaults: UserDefaults? = ChatDirectory.sharedDefaults, now: Date = .now) -> Set<String> {
        let horizon = now.addingTimeInterval(-30 * 24 * 3600).timeIntervalSinceReferenceDate
        return Set(chosenDates(in: defaults).filter { $0.value > horizon }.keys)
    }

    private static func chosenDates(in defaults: UserDefaults?) -> [String: Double] {
        defaults?.dictionary(forKey: chosenKey) as? [String: Double] ?? [:]
    }
}
