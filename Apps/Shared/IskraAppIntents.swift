import AppIntents
import IskraCore

// Siri, Shortcuts and Spotlight, from the app itself — no separate extension, because these intents
// only need the shared chat directory the app keeps in the App Group, not a session of their own.
//
// The "which chat" a phrase or a shortcut refers to is a `ChatEntity`, resolved from that directory
// so the picker in Shortcuts fills without waking a client. Opening a chat hands the room to the app
// it launches; sending a message drops it in the outbox the app flushes when it comes up — which is
// why both open the app rather than reaching the network from here.
//
// The user-facing strings are English defaults for now: Siri phrases and intent titles localise
// through the *app* bundle's catalog, which this app does not yet carry (its words live in the
// IskraFeatures package), so translating them is a follow-up rather than a `Strings` lookup.

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
        self.id = entry.accountID.map { "\($0)|\(entry.id)" } ?? entry.id
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

    func perform() async throws -> some IntentResult {
        ChatDirectory.requestOpen(roomID: chat.roomID, accountID: chat.accountID)
        return .result()
    }
}

/// Send a message to a chat. Drops it in the outbox and opens the app, which flushes it into the
/// room's send queue — so the message leaves even though the intent itself never touched the network.
struct SendMessageIntent: AppIntent {
    static var title: LocalizedStringResource { "Send Message" }
    static var openAppWhenRun: Bool { true }

    @Parameter(title: "Chat") var chat: ChatEntity
    @Parameter(title: "Message") var message: String

    func perform() async throws -> some IntentResult {
        ChatDirectory.enqueue(.init(roomID: chat.roomID, text: message, accountID: chat.accountID))
        // Open the chat too, so the sender can see it land.
        ChatDirectory.requestOpen(roomID: chat.roomID, accountID: chat.accountID)
        return .result()
    }
}

/// The phrases Siri listens for, and the ready-made shortcuts.
struct IskraShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: OpenChatIntent(),
                    phrases: ["Open a chat in \(.applicationName)"],
                    shortTitle: "Open Chat",
                    systemImageName: "bubble.left")
        AppShortcut(intent: SendMessageIntent(),
                    phrases: ["Send a message with \(.applicationName)"],
                    shortTitle: "Send Message",
                    systemImageName: "paperplane")
    }
}
