import Foundation
import Observation

/// The sessions this device has already seen on the account, so that one it has not can be asked
/// about — Telegram's "New login. Was this you?" at the top of the chat list.
///
/// Matrix has no event for "somebody signed in to your account": a new session is simply there the
/// next time the list is read. So the list is read (on start and on every return to the foreground)
/// and compared with the IDs written down here. The first read for an account writes everything down
/// and asks nothing — the sessions somebody already had before this existed are not news.
///
/// Kept per account, in `UserDefaults.standard`: a list of device IDs is not a secret (the server
/// hands it to every session of the account), and it belongs to this device's memory of the account,
/// not to the account.
public struct KnownDevices {
    public static let storageKey = "devices.known"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The IDs known for this account, or nil if it has never been looked at.
    func known(for account: String) -> Set<String>? {
        guard let all = defaults.dictionary(forKey: Self.storageKey) as? [String: [String]],
              let ids = all[account] else { return nil }
        return Set(ids)
    }

    func set(_ ids: Set<String>, for account: String) {
        var all = defaults.dictionary(forKey: Self.storageKey) as? [String: [String]] ?? [:]
        all[account] = ids.sorted()
        defaults.set(all, forKey: Self.storageKey)
    }

    /// Takes a signed-out account's memory away with it.
    public func forget(account: String) {
        var all = defaults.dictionary(forKey: Self.storageKey) as? [String: [String]] ?? [:]
        all[account] = nil
        defaults.set(all, forKey: Self.storageKey)
    }

    /// What to ask about, given the list the server sent: every session that is not this one and
    /// is not known. Writes down the answer to "what exists" as it goes — a session that has gone
    /// is forgotten, and on the very first look everything is known and nothing is asked.
    func newSessions(in devices: [AccountDevice], account: String) -> [AccountDevice] {
        let listed = Set(devices.map(\.id))
        guard let known = known(for: account) else {
            set(listed, for: account)
            return []
        }
        let stillThere = known.intersection(listed)
        if stillThere != known { set(stillThere, for: account) }
        return devices.filter { !$0.isCurrent && !stillThere.contains($0.id) }
    }

    func confirm(_ id: String, for account: String) {
        set((known(for: account) ?? []).union([id]), for: account)
    }
}

/// The sessions on the account that this device has not seen before, for the banner at the top of
/// the chat list. "Yes, it was me" writes one down; "No" is the Devices screen's to act on — ending a
/// session may need the password or the server's page, and that flow lives with `DevicesStore`.
@MainActor
@Observable
public final class NewSignInsStore {
    /// Newest first — the list's own order, by when each was last seen.
    public private(set) var sessions: [AccountDevice] = []

    @ObservationIgnored private let source: AccountDevices
    @ObservationIgnored private let account: String
    @ObservationIgnored private let known: KnownDevices
    @ObservationIgnored private var isChecking = false

    public init(source: AccountDevices, account: String, known: KnownDevices = KnownDevices()) {
        self.source = source
        self.account = account
        self.known = known
    }

    /// Reads the list again. Quietly: a list that will not come is not worth a word here — the
    /// banner is a courtesy, and the Devices screen says it properly when somebody goes looking.
    public func check() async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        guard let devices = try? await source.list() else { return }
        sessions = known.newSessions(in: devices, account: account)
    }

    public func confirm(_ id: String) {
        known.confirm(id, for: account)
        sessions.removeAll { $0.id == id }
    }

    /// The session was ended from the banner's sheet; it is not news any more, and it is not known
    /// either — it no longer exists.
    public func ended(_ id: String) {
        sessions.removeAll { $0.id == id }
    }

    /// A store for ending one of them, over the same source.
    public func devicesStore() -> DevicesStore {
        DevicesStore(source: source)
    }
}
