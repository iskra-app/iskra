import Foundation

/// Bubbles on two sides, or one plain column.
///
/// Bubbles are the default and are meant to stay the common case: a side of the screen and a
/// colour are how a conversation has said who is speaking for as long as conversations have
/// been drawn on phones, and they say it without a word. What this is for is the reader who
/// wants more of the conversation on the screen than bubbles will ever give them — half the
/// width of a Mac window goes to saying whose turn it was — and who is willing to give up their
/// own messages standing out in order to get it.
///
/// Because that is the trade, and it is not a small one. In the compact column nothing stands
/// out: your messages look exactly like everyone else's, and the name above a run is the only
/// thing left saying who spoke. Which is why the name is not optional there, not even in a
/// conversation with one other person — see `CompactMessageRow`.
///
/// One key, written by the appearance screen and read where the conversation is drawn, the same
/// way the accent and the light travel — see `AccentTheme.storageKey` and `AppearanceMode`.
public enum MessageLayout: String, CaseIterable, Identifiable, Sendable {
    case bubbles, compact

    public static let `default` = MessageLayout.bubbles

    public static let storageKey = "messages.layout"

    public var id: String { rawValue }
}
