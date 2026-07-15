import Foundation

/// One chat, as Siri and Shortcuts need to know it: an ID and a name, and nothing that has to be
/// fetched. Written by the app to the shared defaults whenever the room list changes, and read by
/// the App Intents — which may run in a process that has no session of its own — so the "which chat"
/// question is answered from a cache, not by standing up a client.
public struct ChatDirectoryEntry: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
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
    private static let outboxKey = "appIntents.outbox"

    /// The App-Group defaults the app and its intents share.
    public static var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: AppEnvironment.appGroupIdentifier)
    }

    // MARK: - The directory

    public static func writeDirectory(_ entries: [ChatDirectoryEntry], to defaults: UserDefaults? = sharedDefaults) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults?.set(data, forKey: directoryKey)
    }

    public static func directory(from defaults: UserDefaults? = sharedDefaults) -> [ChatDirectoryEntry] {
        guard let data = defaults?.data(forKey: directoryKey),
              let entries = try? JSONDecoder().decode([ChatDirectoryEntry].self, from: data)
        else { return [] }
        return entries
    }

    // MARK: - Opening a chat

    public static func requestOpen(roomID: String, in defaults: UserDefaults? = sharedDefaults) {
        defaults?.set(roomID, forKey: pendingOpenKey)
    }

    /// Reads and clears the pending open — so the app acts on it once, not on every foreground.
    public static func takePendingOpen(from defaults: UserDefaults? = sharedDefaults) -> String? {
        guard let id = defaults?.string(forKey: pendingOpenKey) else { return nil }
        defaults?.removeObject(forKey: pendingOpenKey)
        return id
    }

    // MARK: - The send outbox

    public struct OutboxItem: Codable, Sendable, Equatable {
        public let roomID: String
        public let text: String
        public init(roomID: String, text: String) {
            self.roomID = roomID
            self.text = text
        }
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
    public static func drainOutbox(from defaults: UserDefaults? = sharedDefaults) -> [OutboxItem] {
        let items = outbox(from: defaults)
        defaults?.removeObject(forKey: outboxKey)
        return items
    }
}
