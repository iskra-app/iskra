import AppIntents
import IskraCore

// The chat as an intent parameter, and the intent that opens one — compiled into the app *and* the
// widget extension (`Apps/project.yml`), like `PushFace`. The favourites widget is configured with
// these chats and opens them with this intent, and a widget's configuration has to be the very same
// type in both bundles: two look-alike copies would be two types, and every chat somebody picked
// would fail to resolve on the other side. `perform` runs in the app, which the intent opens.

/// A chat, as an intent parameter.
///
/// Its ID is the room *and whose it is* — `account|room` — because two accounts on one phone can be
/// in the same room, and "send this to Кухня" has to know which of them is saying it. A shortcut
/// saved before there could be two holds the bare room ID, and still resolves.
struct ChatEntity: AppEntity, Identifiable {
    let id: String
    let name: String
    let roomID: String
    let accountID: String?
    /// Shown under the name only when the same device has more than one account to tell apart.
    let accountName: String?

    init(_ entry: ChatDirectoryEntry, showsAccount: Bool) {
        self.id = entry.entityID
        self.name = entry.name
        self.roomID = entry.id
        self.accountID = entry.accountID
        self.accountName = showsAccount ? entry.accountName : nil
    }

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Chat" }
    static let defaultQuery = ChatQuery()

    var displayRepresentation: DisplayRepresentation {
        if let accountName {
            return DisplayRepresentation(title: "\(name)", subtitle: "\(accountName)")
        }
        return DisplayRepresentation(title: "\(name)")
    }
}

/// Resolves chats from the App-Group directory the app maintains — no client, no network.
struct ChatQuery: EntityQuery {
    private func entities() -> [ChatEntity] {
        let entries = ChatDirectory.directory()
        let showsAccount = Set(entries.compactMap(\.accountID)).count > 1
        return entries.map { ChatEntity($0, showsAccount: showsAccount) }
    }

    func entities(for identifiers: [ChatEntity.ID]) async throws -> [ChatEntity] {
        let all = entities()
        // The composite ID first; a bare room ID — from a shortcut older than accounts — then
        // takes the first account that has that room.
        return identifiers.compactMap { id in
            all.first { $0.id == id } ?? all.first { $0.roomID == id }
        }
    }

    func suggestedEntities() async throws -> [ChatEntity] {
        entities()
    }
}

/// Open a specific chat. Hands the room to the app it launches through the shared defaults.
struct OpenChatIntent: AppIntent {
    static var title: LocalizedStringResource { "Open Chat" }
    static var openAppWhenRun: Bool { true }

    @Parameter(title: "Chat") var chat: ChatEntity

    init() {}

    /// For the widget's faces, each of which opens its own chat.
    init(chat: ChatEntity) {
        self.chat = chat
    }

    func perform() async throws -> some IntentResult {
        ChatDirectory.requestOpen(roomID: chat.roomID, accountID: chat.accountID)
        return .result()
    }
}
