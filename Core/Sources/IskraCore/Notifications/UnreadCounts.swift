import Foundation

/// How much is waiting for each account on the device, and so what the icon says.
///
/// One number on the icon used to be one account's number, and there were two people setting it:
/// the app, from the room list, and the notification extension, from the `unread_count` the server
/// sends with every push. With two accounts that is two servers each writing *their* count over the
/// other's — a push for the second account takes the badge down to its own two messages while the
/// first account has forty waiting.
///
/// So each account's count is kept here, in the App Group's defaults where both processes can reach
/// it, and the icon shows the sum. The app writes the count of the account on screen; the extension
/// writes the count of the account a push is for; the accounts nobody is looking at keep the last
/// number anybody knew, which is also what the account switcher shows beside them.
public enum UnreadCounts {
    private static let key = "badge.byAccount"

    public static var defaults: UserDefaults? { ChatDirectory.sharedDefaults }

    public static func all(in defaults: UserDefaults? = defaults) -> [String: Int] {
        defaults?.dictionary(forKey: key) as? [String: Int] ?? [:]
    }

    public static func count(forAccount id: String, in defaults: UserDefaults? = defaults) -> Int {
        all(in: defaults)[id] ?? 0
    }

    /// Writes one account's count, and returns what the icon should now say.
    @discardableResult
    public static func set(_ count: Int, forAccount id: String, in defaults: UserDefaults? = defaults) -> Int {
        var table = all(in: defaults)
        if table[id] != count {
            table[id] = max(0, count)
            defaults?.set(table, forKey: key)
        }
        return total(of: table)
    }

    /// The account is gone; so is its number. Returns what the icon should now say.
    @discardableResult
    public static func forget(account id: String, in defaults: UserDefaults? = defaults) -> Int {
        var table = all(in: defaults)
        table.removeValue(forKey: id)
        defaults?.set(table, forKey: key)
        return total(of: table)
    }

    /// Nobody is signed in any more.
    public static func forgetAll(in defaults: UserDefaults? = defaults) {
        defaults?.removeObject(forKey: key)
    }

    public static func total(in defaults: UserDefaults? = defaults) -> Int {
        total(of: all(in: defaults))
    }

    private static func total(of table: [String: Int]) -> Int {
        table.values.reduce(0, +)
    }
}
