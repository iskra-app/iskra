import Foundation
import Synchronization

/// What *you* call somebody, as opposed to what they call themselves.
///
/// A Matrix display name belongs to the person who set it. A chat with one other person has no
/// name of its own — the header falls back to whoever is on the other end of it (see
/// `RoomInfo.title(besides:)`) — so a contact saved on this phone as «Мама» arrives in the list
/// as `anna_1987`, and there is nothing in the protocol to do about it. Renaming the *room* is
/// the one thing the protocol does offer, and it is exactly the wrong thing: `m.room.name` in a
/// personal chat is a state event that the other person receives, sees, and can undo. Deciding
/// privately what to call a friend must not be an announcement to that friend.
///
/// So the name is kept here, on the device, and the server is never told. Three properties follow
/// from that and all three are promises to the user:
///
/// - **It does not sync.** Another phone signed into the same account knows nothing about it.
///   That is a real limitation and the screen that sets it says so out loud — it is not a bug to
///   be fixed later by putting these in account data, because account data is on the server and
///   this is the one thing that must not be.
/// - **It is not a secret.** It lives in the App Group's `UserDefaults`, in the clear, beside the
///   chat directory Shortcuts reads. A nickname is not a message; the encrypted store is for
///   things that would harm somebody if read, and «Мама» is not one of them — while putting it in
///   the Keychain would make it unreadable to the notification extension, which is precisely
///   where it is most wanted.
/// - **It follows the person everywhere in the app**, because it is applied at the one place the
///   name of a room is computed. The chat list, the header above the conversation, the info
///   screen, the forward picker and the lock screen all get it without asking.
///
/// Only personal chats. A group's name is the group's, shared by everybody in it, and quietly
/// showing one person a different one is how two people end up unable to talk about the same room.
public enum LocalNames {
    /// The whole table, `roomID: name`, under one key. One dictionary rather than a key per room
    /// because the room list asks for *every* room's name on each rebuild, and `UserDefaults`
    /// keeps a decoded value in memory: one lookup that hits a cache beats two hundred that do.
    ///
    /// One table *per account*, under `rooms.localNames.<sessionID>`. Two people on one phone can
    /// be in the same room — the same room ID — and one person's «Мама» must not become the other
    /// one's name for whoever is at the far end.
    private static let legacyKey = "rooms.localNames"

    /// Whose table is being read: the account on screen in the app, the account a push is for in
    /// the notification extension. Process-wide, like the table itself, because the six places
    /// that ask for a name are deep in stores that have no business being handed an account.
    private static let account = Mutex<String?>(nil)

    /// Says whose nicknames are meant from now on. Called when a session opens.
    public static func use(account id: String?) {
        account.withLock { $0 = id }
    }

    /// The account whose table a call without one reads.
    public static var currentAccount: String? { account.withLock { $0 } }

    private static func key(for account: String?) -> String {
        account.map { "\(legacyKey).\($0)" } ?? legacyKey
    }

    /// Gives the table from before accounts were separate to the account that was signed in then.
    /// Called once, by the Keychain migration, which is the one thing that knows who that was.
    public static func adoptLegacyTable(forAccount id: String, in defaults: UserDefaults? = defaults) {
        guard let legacy = defaults?.dictionary(forKey: legacyKey) else { return }
        if defaults?.dictionary(forKey: key(for: id)) == nil {
            defaults?.set(legacy, forKey: key(for: id))
        }
        defaults?.removeObject(forKey: legacyKey)
    }

    /// Somebody renamed a chat — or gave a name back. Posted so the screens already on show can
    /// catch up: the room list, the open conversation's header and the info screen each hold a
    /// name they computed earlier, and nothing in the SDK is going to tell them it has changed,
    /// because as far as the SDK is concerned nothing has.
    ///
    /// `userInfo["roomID"]` is the room it happened to.
    public static let didChange = Notification.Name("wtf.iskra.localNameDidChange")

    /// The App Group's defaults — the same suite the chat directory uses, and for the same
    /// reason: the notification extension is a second process, and a nickname that the lock
    /// screen does not know about is a nickname the user will assume is broken.
    /// Public because it is the default argument of the public calls below, and Swift wants a
    /// default argument to be as visible as the function it belongs to.
    public static var defaults: UserDefaults? { ChatDirectory.sharedDefaults }

    // MARK: - Reading

    /// The name this device has been told to use for a chat, or nil to use the one the server
    /// gives. Empty strings never come back out: a name of no characters is an absence, and a
    /// header with nothing in it is worse than a Matrix ID.
    public static func name(for roomID: String,
                            account: String? = currentAccount,
                            in defaults: UserDefaults? = defaults) -> String? {
        guard let stored = table(account: account, in: defaults)[roomID] else { return nil }
        let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Whether any chat at all has been renamed. The info screen asks, so that a chat with no
    /// nickname shows the field empty with the real name behind it as a placeholder.
    static func table(account: String? = currentAccount,
                      in defaults: UserDefaults? = defaults) -> [String: String] {
        defaults?.dictionary(forKey: key(for: account)) as? [String: String] ?? [:]
    }

    // MARK: - Writing

    /// Sets the name, or — given nil or blank — gives the real one back.
    ///
    /// Trimmed on the way in, so a stray space is not a rename, and compared before writing: an
    /// edit that changes nothing must not wake every screen in the app.
    public static func set(_ name: String?,
                           for roomID: String,
                           account: String? = currentAccount,
                           in defaults: UserDefaults? = defaults) {
        let trimmed = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        var table = table(account: account, in: defaults)
        let previous = table[roomID]
        if trimmed.isEmpty {
            table.removeValue(forKey: roomID)
        } else {
            table[roomID] = trimmed
        }
        guard previous != table[roomID] else { return }

        defaults?.set(table, forKey: key(for: account))
        NotificationCenter.default.post(name: didChange, object: nil, userInfo: ["roomID": roomID])
    }

    /// Forgets every one of them.
    ///
    /// Called when the session is destroyed, and it has to be: these names are one person's
    /// private notes about the people they talk to, they are stored in the clear, and the next
    /// account signed in on this device is somebody else. They are also keyed by room ID, which
    /// means they would otherwise reattach themselves to rooms a *different* account happens to
    /// share — the same room, the same ID, somebody else's nickname for whoever is in it.
    ///
    /// One account's: the others on the device are still signed in, and their names are theirs.
    public static func forget(account id: String? = currentAccount, in defaults: UserDefaults? = defaults) {
        defaults?.removeObject(forKey: key(for: id))
    }

    // MARK: - Hearing about it

    /// Watching for a rename, for the stores that are already holding a name when one happens.
    ///
    /// The handler is given the room it happened to, and is called on the main actor — the three
    /// stores that want this are all `@MainActor`, and hopping through a `Task` would let a redraw
    /// land between the write and the screen catching up.
    ///
    /// The returned object *is* the subscription: hold it for as long as the notifications are
    /// wanted, and let go of it to stop them.
    @MainActor
    static func observe(_ handler: @escaping @Sendable @MainActor (String?) -> Void) -> LocalNameSubscription {
        let token = NotificationCenter.default.addObserver(forName: didChange, object: nil, queue: .main) { note in
            let roomID = note.userInfo?["roomID"] as? String
            // `queue: .main` is the guarantee that this *is* the main thread; the compiler has no
            // way to know it, and a `Task` hop here would be a redraw's worth of the old name.
            MainActor.assumeIsolated { handler(roomID) }
        }
        return LocalNameSubscription(token: token)
    }
}

/// A subscription to `LocalNames.didChange` that unsubscribes when it is released.
///
/// A block observer outlives the object that registered it — `NotificationCenter` keeps the block,
/// and a weakly captured store that has gone leaves a block that runs and does nothing, forever,
/// once per room ever opened. The stores that want one hold this instead, and the arithmetic is
/// then the ordinary arithmetic of a stored property.
///
/// Deliberately *not* `@MainActor`: a `deinit` on an isolated class cannot touch a non-`Sendable`
/// stored property, and the token is one. `removeObserver` is safe from any thread.
final class LocalNameSubscription {
    private let token: any NSObjectProtocol

    init(token: any NSObjectProtocol) {
        self.token = token
    }

    deinit {
        NotificationCenter.default.removeObserver(token)
    }
}
