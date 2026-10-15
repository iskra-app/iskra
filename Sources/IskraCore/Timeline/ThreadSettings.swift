import Foundation

/// Whether answers in threads are kept under their message (on), or shown in the room among
/// everything else (off) — Settings → Chats. On by default.
///
/// Off is what a person who never uses threads, in rooms where other people do, may want: a
/// conversation that reads top to bottom with nothing folded away. Answers are still answers — the
/// SDK marks each with the message it is in reply to — and the room shows them as ordinary
/// messages. Read when a room's timeline is opened: a timeline cannot change its focus while open.
public enum ThreadSettings {
    public static let isEnabledKey = "chats.threads"
    public static let isEnabledByDefault = true
    public static let keys = [isEnabledKey]

    public static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: isEnabledKey) as? Bool ?? isEnabledByDefault
    }
}
