import Foundation

/// A folder of chats, as Telegram has them: a name, and a rule for which chats are in it.
///
/// The rule is a few kinds of chat — personal, groups, spaces, invitations — narrowed by
/// conditions — only the unread ones, none of the silenced ones, the archive too or not — and
/// overruled by name: chats added by hand are in whatever the kinds say, chats left out by hand are
/// out whatever anything says. A folder is a *filter*, never a copy: the order inside it is the
/// list's own, and a chat is in as many folders as describe it.
///
/// Matrix has nothing like it — the nearest are tags, which are one per chat and per account, not
/// rules — so the folders live in the account's data under a key of this app's own, and travel to
/// every device the account is signed in on, as Telegram's do.
public struct ChatFolder: Codable, Sendable, Identifiable, Equatable, Hashable {
    public var id: String
    public var name: String

    /// The kinds of chat the folder takes. See `Kind`.
    public var kinds: Set<Kind>

    /// Only chats with something unread — Telegram's "exclude read".
    public var onlyUnread: Bool
    /// No chat that has been silenced by name.
    public var excludesMuted: Bool
    /// The archive too. Off by default, as in Telegram: what was swept away stays away.
    public var includesArchived: Bool

    /// Always in, whatever the kinds say — though the conditions still apply. By room ID.
    public var included: [String]
    /// Always out. Beats everything else.
    public var excluded: [String]

    public enum Kind: String, Codable, Sendable, CaseIterable, Identifiable {
        case direct
        case groups
        case spaces
        case invitations

        public var id: String { rawValue }
    }

    public init(id: String = UUID().uuidString, name: String, kinds: Set<Kind> = [],
                onlyUnread: Bool = false, excludesMuted: Bool = false, includesArchived: Bool = false,
                included: [String] = [], excluded: [String] = []) {
        self.id = id
        self.name = name
        self.kinds = kinds
        self.onlyUnread = onlyUnread
        self.excludesMuted = excludesMuted
        self.includesArchived = includesArchived
        self.included = included
        self.excluded = excluded
    }

    /// Whether this chat is in the folder.
    public func contains(_ room: RoomSummary) -> Bool {
        if excluded.contains(room.id) { return false }
        if room.isArchived, !includesArchived { return false }
        if excludesMuted, room.isMuted { return false }
        if onlyUnread, !room.hasUnread, !room.isInvitation { return false }
        return included.contains(room.id) || kinds.contains(Kind(of: room))
    }

    /// The folder's chats, out of the list's — in the list's order.
    public func rooms(from rooms: [RoomSummary], archived: [RoomSummary] = []) -> [RoomSummary] {
        (includesArchived ? rooms + archived : rooms).filter(contains)
    }

    /// Whether the folder could ever hold anything — a name and no rule is a folder that is always
    /// empty, and the editor will not save one.
    public var isMeaningful: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (!kinds.isEmpty || !included.isEmpty)
    }
}

extension ChatFolder.Kind {
    init(of room: RoomSummary) {
        if room.isInvitation { self = .invitations }
        else if room.isSpace { self = .spaces }
        else if room.isDirectMessage { self = .direct }
        else { self = .groups }
    }
}

public extension ChatFolder {
    /// What the editor offers to start from — Telegram's suggested folders.
    static func suggestions(named name: (Suggestion) -> String) -> [ChatFolder] {
        Suggestion.allCases.map { suggestion in
            switch suggestion {
            case .personal: ChatFolder(name: name(suggestion), kinds: [.direct])
            case .groups: ChatFolder(name: name(suggestion), kinds: [.groups])
            case .unread: ChatFolder(name: name(suggestion), kinds: [.direct, .groups], onlyUnread: true)
            }
        }
    }

    enum Suggestion: CaseIterable, Sendable {
        case personal
        case groups
        case unread
    }
}

/// The account's folders: read from its account data, written back on every change.
///
/// The whole list is one document, written whole — there are a handful of folders and they change
/// a few times a year, and a merge of two devices' edits is not worth what it would cost to get
/// right. The last write wins, as it does for Telegram's.
@MainActor
@Observable
public final class ChatFolders {
    public private(set) var folders: [ChatFolder] = []
    public private(set) var hasLoaded = false

    /// Set when a change could not be written. The list on the screen is put back.
    public var failure: Failure?

    public enum Failure: String, CaseIterable, ActionFailure {
        case save
        public var id: String { rawValue }
        public var explanation: LocalizedStringResource { CoreStrings.Folders.saveFailed }
    }

    /// Still `moscow.swag.iskra`, the app's old prefix, on purpose: this name lives on the server,
    /// outlives any install and is shared with Android, so renaming it loses what is stored under it.
    nonisolated static let type = "moscow.swag.iskra.chat_folders"
    nonisolated static let timeout: Duration = .seconds(10)
    /// Telegram's limit, and more folders than tabs anybody can read in a row.
    public nonisolated static let limit = 10

    private let readAccountData: @Sendable (String) async throws -> String?
    private let writeAccountData: @Sendable (String, String) async throws -> Void

    init(readAccountData: @escaping @Sendable (String) async throws -> String?,
         writeAccountData: @escaping @Sendable (String, String) async throws -> Void) {
        self.readAccountData = readAccountData
        self.writeAccountData = writeAccountData
    }

    /// Reads the folders. A read that fails leaves what is on the screen; one that finds nothing
    /// is an account with no folders.
    public func load() async {
        let read = readAccountData
        let type = Self.type
        guard let text = try? await withTimeout(Self.timeout, operation: { try await read(type) }) else {
            hasLoaded = true
            return
        }
        folders = Self.decode(text)
        hasLoaded = true
    }

    public func save(_ folder: ChatFolder) async {
        var next = folders
        if let index = next.firstIndex(where: { $0.id == folder.id }) {
            next[index] = folder
        } else {
            guard next.count < Self.limit else { return }
            next.append(folder)
        }
        await write(next)
    }

    public func delete(_ id: String) async {
        await write(folders.filter { $0.id != id })
    }

    public func move(fromOffsets source: IndexSet, toOffset destination: Int) async {
        // `move(fromOffsets:toOffset:)` is SwiftUI's, and this target does not import it.
        let moving = source.map { folders[$0] }
        var next = folders.enumerated().filter { !source.contains($0.offset) }.map(\.element)
        let insertAt = destination - source.filter { $0 < destination }.count
        next.insert(contentsOf: moving, at: min(max(insertAt, 0), next.count))
        await write(next)
    }

    /// Puts a chat in a folder by hand, or takes it out — what the chat's own menu offers.
    public func set(_ roomID: String, in folderID: String, _ isIn: Bool) async {
        guard var folder = folders.first(where: { $0.id == folderID }) else { return }
        folder.included.removeAll { $0 == roomID }
        folder.excluded.removeAll { $0 == roomID }
        if isIn { folder.included.append(roomID) } else { folder.excluded.append(roomID) }
        await save(folder)
    }

    private func write(_ next: [ChatFolder]) async {
        let previous = folders
        folders = next
        let text = Self.encode(next)
        let write = writeAccountData
        let type = Self.type
        do {
            try await withTimeout(Self.timeout) { try await write(type, text) }
        } catch {
            Log.rooms.error("folders were not saved: \(Log.describe(error), privacy: .public)")
            folders = previous
            failure = .save
        }
    }

    // MARK: - The document

    private struct Document: Codable {
        var folders: [ChatFolder]
    }

    nonisolated static func encode(_ folders: [ChatFolder]) -> String {
        let data = (try? JSONEncoder().encode(Document(folders: folders))) ?? Data("{\"folders\":[]}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// Lenient: a folder this version cannot read is skipped, not the whole list — another device
    /// on a newer version may have written a field this one has never heard of.
    nonisolated static func decode(_ text: String) -> [ChatFolder] {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = object["folders"] as? [Any] else { return [] }
        return raw.compactMap { item in
            guard let itemData = try? JSONSerialization.data(withJSONObject: item) else { return nil }
            return try? JSONDecoder().decode(ChatFolder.self, from: itemData)
        }
    }
}
