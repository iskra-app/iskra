import Foundation

/// One chat, as Siri and Shortcuts need to know it: an ID and a name, and nothing that has to be
/// fetched. Written by the app to the shared defaults whenever the room list changes, and read by
/// the App Intents — which may run in a process that has no session of its own — so the "which chat"
/// question is answered from a cache, not by standing up a client.
public struct ChatDirectoryEntry: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String

    /// Whose chat this is, when there is more than one account on the device — the account's
    /// session ID. Nil in a directory written before there could be two, which then belongs to the
    /// only account there was.
    public let accountID: String?

    /// The name of that account, for the share sheet to head a section with. Written down here
    /// because the share extension has no session to ask.
    public let accountName: String?

    /// What the chat's stand-in face is drawn from — `RoomSummary.avatarSeed`, the other person's ID
    /// in a personal chat. For the share sheet's grid, which draws the same creature the chat list
    /// does: the extension cannot fetch a picture (that takes the account's token, and it runs no
    /// session), but it can draw a face from a seed. Nil in a directory written before it was kept.
    public let avatarSeed: String?

    /// The chat's real picture, as a file in `DirectoryFaces.folder()` — downloaded by the app,
    /// which is the only process with a token to download it with. Nil when there is no picture,
    /// when it has not been fetched yet, or when the user asked for creatures everywhere; the
    /// creature from `avatarSeed` is drawn instead in all three. See `DirectoryFaces`.
    public let faceFile: String?

    /// Pinned in the chat list (`m.favourite`) — what the favourites widget shows when nobody chose.
    public let isPinned: Bool?

    /// Unread messages that would have notified, for the widget's dot. A number and not words: the
    /// same thing the icon's badge already says on the home screen.
    public let unreadCount: Int?

    public init(id: String, name: String, accountID: String? = nil, accountName: String? = nil,
                avatarSeed: String? = nil, faceFile: String? = nil, isPinned: Bool? = nil,
                unreadCount: Int? = nil) {
        self.id = id
        self.name = name
        self.accountID = accountID
        self.accountName = accountName
        self.avatarSeed = avatarSeed
        self.faceFile = faceFile
        self.isPinned = isPinned
        self.unreadCount = unreadCount
    }

    /// The chat and whose it is, as one string — `account|room`, or the bare room for an entry
    /// from before there could be two accounts. The same ID `ChatEntity` gives Shortcuts and the
    /// widget, so a chat chosen there is found here.
    public var entityID: String {
        accountID.map { "\($0)|\(id)" } ?? id
    }
}

/// The small shared surface App Intents talk to the app across. Three things live in the App-Group
/// defaults: the directory of chats (so Shortcuts can list them), a pending "open this chat" request
/// (so an Open-Chat intent can hand a room to the app it just launched), and an outbox of messages
/// an intent asked to send (which the app flushes when it comes up, so a Send-Message intent does
/// not need a whole background client of its own).
public enum ChatDirectory {
    private static let directoryKey = "appIntents.chatDirectory"
    private static let pendingOpenKey = "appIntents.pendingOpenRoom"
    private static let pendingOpenAccountKey = "appIntents.pendingOpenAccount"
    private static let outboxKey = "appIntents.outbox"

    /// The App-Group defaults the app and its intents share.
    public static var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: AppEnvironment.appGroupIdentifier)
    }

    // MARK: - The directory

    ///
    /// - Parameter account: whose chats these are. Only that account's entries are replaced, and
    ///   every other account's stay — the account on screen is the only one whose list is live, and
    ///   the others' are what they were when they were last open. Nil replaces the whole directory.
    public static func writeDirectory(_ entries: [ChatDirectoryEntry],
                                      account: String? = nil,
                                      to defaults: UserDefaults? = sharedDefaults) {
        var all = entries
        if let account {
            // Entries with no account are from before there could be two, and are the old list of
            // the account writing now — or of nobody still here. Either way they are replaced.
            all = directory(from: defaults).filter { $0.accountID != nil && $0.accountID != account } + entries
        }
        guard let data = try? JSONEncoder().encode(all) else { return }
        defaults?.set(data, forKey: directoryKey)
    }

    /// Takes a signed-out account's chats out of Siri's list and the share sheet.
    public static func forget(account: String, in defaults: UserDefaults? = sharedDefaults,
                              faces: URL? = try? DirectoryFaces.folder()) {
        let entries = directory(from: defaults)
        let kept = entries.filter { $0.accountID != account }
        guard let data = try? JSONEncoder().encode(kept) else { return }
        defaults?.set(data, forKey: directoryKey)
        // Its faces too, the same lesson as the outbox's copies below — except a picture another
        // account on the device also has a chat with, which is still theirs to show.
        if let faces {
            let gone = Set(entries.filter { $0.accountID == account }.compactMap(\.faceFile))
                .subtracting(kept.compactMap(\.faceFile))
            DirectoryFaces.remove(gone, in: faces)
        }
        let all = outbox(from: defaults)
        let outbox = all.filter { $0.accountID != account }
        if let data = try? JSONEncoder().encode(outbox) {
            defaults?.set(data, forKey: outboxKey)
        }
        // And the files: forgetting the entries and leaving the copies behind left somebody's
        // photos in the clear in the shared container, after the account they were for had gone.
        if let folder = try? outboxFolder() {
            for item in all where item.accountID == account {
                for attachment in item.attachments {
                    if let slot = attachment.location(in: folder)?.slot {
                        try? FileManager.default.removeItem(at: slot)
                    }
                }
            }
        }
    }

    /// Throws away every copy in the outbox that no queued item points at and that is older than
    /// `age` — what a share sheet swiped away, killed for memory, or opened with nothing to send to
    /// leaves behind. Called at launch.
    ///
    /// The age is there for the one copy that is *meant* to be unreferenced: the Share extension
    /// copies a file the moment it is shown, before the user has picked a chat, and a share sheet
    /// may be open beside the app on an iPad while it launches.
    public static func sweepOutbox(olderThan age: TimeInterval = 3600,
                                   in defaults: UserDefaults? = sharedDefaults, now: Date = .now) {
        guard let folder = try? outboxFolder() else { return }
        let referenced = Set(outbox(from: defaults).flatMap(\.attachments).compactMap {
            $0.location(in: folder)?.slot.lastPathComponent
        })
        let slots = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.creationDateKey])) ?? []
        for slot in slots where !referenced.contains(slot.lastPathComponent) {
            let created = (try? slot.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
            if now.timeIntervalSince(created) > age {
                try? FileManager.default.removeItem(at: slot)
            }
        }
    }

    public static func directory(from defaults: UserDefaults? = sharedDefaults) -> [ChatDirectoryEntry] {
        guard let data = defaults?.data(forKey: directoryKey),
              let entries = try? JSONDecoder().decode([ChatDirectoryEntry].self, from: data)
        else { return [] }
        return entries
    }

    // MARK: - Whose chats the share sheet shows

    /// Which account the share sheet offers chats from — Settings → Chats.
    public enum ShareAccount: Sendable, Equatable, Hashable {
        /// Whoever is on screen in the app right now. The default: sharing is nearly always "to
        /// the person I was just talking to", and they are in the account that is open.
        case active
        /// One account, always, whichever is open — the work account for a work phone's Share.
        case account(String)
        /// Every account, a block each — how the sheet behaved before there was a choice.
        case all

        init(stored: String?) {
            switch stored {
            case nil, "", Self.activeValue: self = .active
            case Self.allValue: self = .all
            case let id?: self = .account(id)
            }
        }

        var stored: String {
            switch self {
            case .active: Self.activeValue
            case .all: Self.allValue
            case let .account(id): id
            }
        }

        private static let activeValue = "active"
        private static let allValue = "all"
    }

    private static let shareAccountKey = "share.account"
    private static let activeAccountKey = "accounts.active"

    public static func shareAccount(in defaults: UserDefaults? = sharedDefaults) -> ShareAccount {
        ShareAccount(stored: defaults?.string(forKey: shareAccountKey))
    }

    public static func setShareAccount(_ choice: ShareAccount, in defaults: UserDefaults? = sharedDefaults) {
        defaults?.set(choice.stored, forKey: shareAccountKey)
    }

    private static let namesAccountKey = "notifications.namesAccount"

    /// Whether a notification says which account it came for — "@boris:work.example" over the
    /// message — when more than one is signed in. On unless turned off. In the App Group, because the
    /// notification extension is what reads it; see `PushDecoder.accountLabel`.
    public static func namesAccountInNotifications(in defaults: UserDefaults? = sharedDefaults) -> Bool {
        defaults?.object(forKey: namesAccountKey) as? Bool ?? true
    }

    public static func setNamesAccountInNotifications(_ names: Bool, in defaults: UserDefaults? = sharedDefaults) {
        defaults?.set(names, forKey: namesAccountKey)
    }

    /// The account on screen, written down for the share extension — which has no session, and no
    /// business reading the Keychain's account index to find out who is open.
    public static func recordActiveAccount(_ sessionID: String, in defaults: UserDefaults? = sharedDefaults) {
        defaults?.set(sessionID, forKey: activeAccountKey)
    }

    /// The account on screen in the app, as last written — whose chats a widget shows by default.
    public static func activeAccount(in defaults: UserDefaults? = sharedDefaults) -> String? {
        defaults?.string(forKey: activeAccountKey)
    }

    /// The chats the share sheet lists, by the choice above.
    ///
    /// A choice that no longer points anywhere — the account it named was signed out, or nothing
    /// has said yet who is active — falls back to the next widest answer rather than to an empty
    /// sheet: the chosen account becomes the active one, and an unknown active one becomes all.
    public static func shareDirectory(from defaults: UserDefaults? = sharedDefaults) -> [ChatDirectoryEntry] {
        let all = directory(from: defaults)
        let accounts = Set(all.map(\.accountID))
        guard accounts.count > 1 else { return all }

        func only(_ account: String?) -> [ChatDirectoryEntry]? {
            guard let account, accounts.contains(account) else { return nil }
            return all.filter { $0.accountID == account }
        }
        let active = only(defaults?.string(forKey: activeAccountKey))

        switch shareAccount(in: defaults) {
        case .all: return all
        case .active: return active ?? all
        case let .account(id): return only(id) ?? active ?? all
        }
    }

    // MARK: - Opening a chat

    public static func requestOpen(roomID: String, accountID: String? = nil,
                                   in defaults: UserDefaults? = sharedDefaults) {
        defaults?.set(roomID, forKey: pendingOpenKey)
        if let accountID {
            defaults?.set(accountID, forKey: pendingOpenAccountKey)
        } else {
            defaults?.removeObject(forKey: pendingOpenAccountKey)
        }
    }

    /// A chat somebody asked to open, and whose it is.
    public struct OpenRequest: Sendable, Equatable {
        public let roomID: String
        public let accountID: String?
    }

    public static func takePendingOpenRequest(from defaults: UserDefaults? = sharedDefaults) -> OpenRequest? {
        guard let id = defaults?.string(forKey: pendingOpenKey) else { return nil }
        let account = defaults?.string(forKey: pendingOpenAccountKey)
        defaults?.removeObject(forKey: pendingOpenKey)
        defaults?.removeObject(forKey: pendingOpenAccountKey)
        return OpenRequest(roomID: id, accountID: account)
    }

    public static func takePendingOpen(from defaults: UserDefaults? = sharedDefaults) -> String? {
        takePendingOpenRequest(from: defaults)?.roomID
    }

    // MARK: - The send outbox

    public struct OutboxItem: Codable, Sendable, Equatable {
        public let roomID: String
        public let text: String
        /// Pictures, videos and files handed over by the Share extension — each one a file in
        /// `outboxFolder()`, which the app sends and then deletes. Empty for everything Shortcuts
        /// queues, and absent from anything queued by a build that predates it.
        public let attachments: [OutboxAttachment]
        /// Who sends it. Nil in an item queued before there could be two accounts, which is the
        /// account on screen's to send.
        public let accountID: String?

        public init(roomID: String, text: String, attachments: [OutboxAttachment] = [],
                    accountID: String? = nil) {
            self.roomID = roomID
            self.text = text
            self.attachments = attachments
            self.accountID = accountID
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            roomID = try container.decode(String.self, forKey: .roomID)
            text = try container.decode(String.self, forKey: .text)
            attachments = try container.decodeIfPresent([OutboxAttachment].self, forKey: .attachments) ?? []
            accountID = try container.decodeIfPresent(String.self, forKey: .accountID)
        }
    }

    /// One shared thing that is not words.
    public struct OutboxAttachment: Codable, Sendable, Equatable {
        public enum Kind: String, Codable, Sendable {
            case image, video, file
        }

        public let kind: Kind
        /// The file's path inside `outboxFolder()` — a folder of its own and the file's original
        /// name in it, `<uuid>/IMG_0042.HEIC`, so the person it is sent to sees the name it had
        /// and two files called the same thing cannot overwrite each other. A path and not a URL,
        /// because the container is not at the same place in the two processes that read it.
        public let filename: String

        public init(kind: Kind, filename: String) {
            self.kind = kind
            self.filename = filename
        }

        /// Where the file is, and the folder of its own it sits in — or `nil` if `filename` is
        /// anything but `<folder>/<name>` directly inside the outbox.
        ///
        /// The outbox entry is written by another process, and its name came from another app;
        /// the folder returned here is what gets *deleted* once the file is sent. So nothing is
        /// resolved that could climb out: two components, both plain names.
        public func location(in outbox: URL) -> (file: URL, slot: URL)? {
            let parts = filename.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2, parts.allSatisfy(SafeFilename.isSafe) else { return nil }
            let slot = outbox.appending(component: parts[0], directoryHint: .isDirectory)
            return (slot.appending(component: parts[1]), slot)
        }

        /// The name the file goes out under — its own, without the folder it waited in.
        public var displayName: String {
            (filename as NSString).lastPathComponent
        }
    }

    /// Where the Share extension leaves the files it was given, until the app sends them.
    ///
    /// In the App Group because it is the only place both processes can reach. They are the
    /// user's pictures in the clear for as long as they wait there — the extension cannot encrypt
    /// them for a room, only the SDK in the app can — so the folder is kept out of backups, and
    /// every file is deleted the moment its send has been handed to the queue.
    public static func outboxFolder(environment: AppEnvironment = .default) throws -> URL {
        var folder = try environment.containerURL().appending(component: "Outbox")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
        return folder
    }

    public static func enqueue(_ item: OutboxItem, in defaults: UserDefaults? = sharedDefaults) {
        var items = outbox(from: defaults)
        items.append(item)
        if let data = try? JSONEncoder().encode(items) {
            defaults?.set(data, forKey: outboxKey)
        }
    }

    static func outbox(from defaults: UserDefaults? = sharedDefaults) -> [OutboxItem] {
        guard let data = defaults?.data(forKey: outboxKey),
              let items = try? JSONDecoder().decode([OutboxItem].self, from: data)
        else { return [] }
        return items
    }

    /// Reads and clears the outbox — the app sends each item, once.
    ///
    /// - Parameter account: take only what this account sends (and what nobody was named for), and
    ///   leave everybody else's waiting for their own account to be opened. Nil takes everything.
    public static func drainOutbox(forAccount account: String? = nil,
                                   from defaults: UserDefaults? = sharedDefaults) -> [OutboxItem] {
        let items = outbox(from: defaults)
        guard let account else {
            defaults?.removeObject(forKey: outboxKey)
            return items
        }

        let mine = items.filter { $0.accountID == nil || $0.accountID == account }
        let others = items.filter { $0.accountID != nil && $0.accountID != account }
        if others.isEmpty {
            defaults?.removeObject(forKey: outboxKey)
        } else if let data = try? JSONEncoder().encode(others) {
            defaults?.set(data, forKey: outboxKey)
        }
        return mine
    }

    /// The accounts with something waiting in the outbox, in the order it was queued.
    public static func accountsWaitingToSend(in defaults: UserDefaults? = sharedDefaults) -> [String] {
        var seen: [String] = []
        for id in outbox(from: defaults).compactMap(\.accountID) where !seen.contains(id) {
            seen.append(id)
        }
        return seen
    }
}
