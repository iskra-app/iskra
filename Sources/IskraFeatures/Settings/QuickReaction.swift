import Foundation

/// The emoji a double tap leaves on a message — and, in the same order, the row of them
/// across the top of a message's context menu.
///
/// One list, used twice, deliberately. The six here are the reactions people actually send;
/// a full emoji keyboard hanging off a context menu is a search box in front of a shrug. And
/// the emoji the double tap sends has to be one of the six the menu offers, or the setting
/// would be teaching a gesture nothing else in the app agrees with.
///
/// The choice is a `RawRepresentable` string, which is what lets `@AppStorage` keep it
/// without any coding of our own — and the raw value is the emoji itself, so what is written
/// to disk is readable and what comes back is already the thing to send.
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
    static let storageKey = "reactions.quick"

    var id: String { rawValue }

    /// The emoji, which is all a reaction ever is — Matrix calls it the reaction's key.
    var key: String { rawValue }
}
