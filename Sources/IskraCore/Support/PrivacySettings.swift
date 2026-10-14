import Foundation

/// What other people are told about you without your writing anything: that you are online, and
/// that you are typing.
///
/// Read at the moment it matters — a keystroke, a trip back into the foreground — from
/// `UserDefaults.standard`, where Settings → Privacy writes it through `@AppStorage` with these same
/// keys and defaults. Both are off by default, as they are in every messenger: hiding them is a
/// choice somebody makes, not one made for them.
///
/// Hiding your last-seen time hides everybody else's from you too, as in Telegram — see
/// `seesOthersPresence`. Hiding typing does not: "печатает…" from others keeps arriving, because a
/// server that relays typing does not ask the reader's permission.
public enum PrivacySettings {
    /// Whether the account tells the homeserver it is offline whatever it is doing, so nobody sees
    /// when it was last here.
    public static let hidesPresenceKey = "privacy.hidesPresence"
    public static let hidesPresenceByDefault = false

    /// Whether typing a message stays between you and the composer.
    public static let hidesTypingKey = "privacy.hidesTyping"
    public static let hidesTypingByDefault = false

    public static func hidesPresence(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: hidesPresenceKey) as? Bool ?? hidesPresenceByDefault
    }

    /// Whether the app asks the server where other people are. Never while your own is hidden:
    /// watching people while hiding from them is the one combination the switch rules out, and it
    /// is ruled out here, where `TimelineStore.watchPresence` asks, rather than in a view that could
    /// forget.
    public static func seesOthersPresence(_ defaults: UserDefaults = .standard) -> Bool {
        !hidesPresence(defaults)
    }

    public static func hidesTyping(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: hidesTypingKey) as? Bool ?? hidesTypingByDefault
    }

    /// Every key, for `AppSettings.forget`.
    public static let keys = [hidesPresenceKey, hidesTypingKey]
}
