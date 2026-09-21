import Foundation

/// The six emoji offered first — across the top of a message's context menu, and as the row of
/// shortcuts on the reactions screen.
///
/// They are *suggestions*, not the whole of what can be chosen. The emoji a double tap leaves is
/// stored as a plain string (`storageKey`), and it may be any emoji at all: the settings screen
/// opens the same picker the "+" on the menu bar opens, so the gesture can send whatever the
/// menu can — see `EmojiPanel`. Limiting the setting to these six meant a person whose reaction
/// is 🔥 had to settle for one of somebody else's, which is a strange thing for a preference to
/// insist on.
///
/// What the six are still for is the shortcut. A full emoji keyboard as the *first* thing on
/// either screen is a search box in front of a shrug; these are the reactions people actually
/// send, they are one tap, and everything else is one tap further.
enum QuickReaction: String, CaseIterable, Identifiable, Sendable {
    case heart = "❤️"
    case thumbsUp = "👍"
    case laugh = "😂"
    case surprise = "😮"
    case sad = "😢"
    case thanks = "🙏"

    /// A heart, because a double tap on a message means "yes, this" in every app that has
    /// ever had one, and a thumbs-up is a colder thing to say by accident.
    static let `default` = QuickReaction.heart

    /// Where the choice is kept: one key, written by the settings screen and read by every
    /// message row.
    ///
    /// What is written there is the emoji itself — which is what it has always been, so a
    /// setting made back when this enum *was* the storage type reads back unchanged now that
    /// the stored type is a string.
    static let storageKey = "reactions.quick"

    /// What the double tap sends until somebody says otherwise. A `String`, because that is the
    /// type the setting now has.
    static let defaultKey = QuickReaction.default.rawValue

    var id: String { rawValue }

    /// The emoji, which is all a reaction ever is — Matrix calls it the reaction's key.
    var key: String { rawValue }

    /// The six as plain strings, for the places that only want the characters.
    static let keys = allCases.map(\.rawValue)
}
