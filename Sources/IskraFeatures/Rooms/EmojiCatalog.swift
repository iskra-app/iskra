import Foundation
import SwiftUI

/// Every emoji the "+" in a message's menu offers, in the order a person looks for them.
///
/// Hand-written, and deliberately not the whole of Unicode. A complete table is four thousand
/// characters long, most of which nobody has ever sent to anybody, and shipping it would mean
/// shipping a *search box* as well — because four thousand is only findable by name, and names
/// mean an English-and-Russian dictionary of four thousand entries to go with them. What is here
/// instead is the few hundred that people actually react with, grouped so the eye can sweep a
/// category and stop. That is a smaller promise, and unlike the other one it is kept.
///
/// There is no search field for the same reason. A grid of nine categories is scanned; a search
/// box over a list this size would be a text field in front of two flicks of the thumb.
///
/// The characters are written out as literals rather than built from scalars. It makes this file
/// long and it makes it *checkable*: what is in the source is what lands on the message.
enum EmojiCatalog {
    /// A group of emoji, and the tab that selects it.
    struct Category: Identifiable, Hashable {
        let id: String
        /// The tab's icon. An SF Symbol, because a category shown as one of its own members —
        /// a smiley standing for "smileys" — is indistinguishable from an emoji you can send.
        let symbol: String
        let title: LocalizedStringResource
        let emoji: [String]

        static func == (lhs: Category, rhs: Category) -> Bool { lhs.id == rhs.id }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    /// The order they appear in, left to right. Hearts come second — before the faces most
    /// tables put first — because a reaction is more often an agreement than an expression,
    /// and the six on the bar outside say the same thing.
    static let categories: [Category] = [
        Category(id: "smileys", symbol: "face.smiling", title: Strings.Reactions.smileys, emoji: smileys),
        Category(id: "gestures", symbol: "hand.thumbsup", title: Strings.Reactions.gestures, emoji: gestures),
        Category(id: "hearts", symbol: "heart", title: Strings.Reactions.hearts, emoji: hearts),
        Category(id: "animals", symbol: "pawprint", title: Strings.Reactions.animals, emoji: animals),
        Category(id: "food", symbol: "fork.knife", title: Strings.Reactions.food, emoji: food),
        Category(id: "activity", symbol: "figure.run", title: Strings.Reactions.activity, emoji: activity),
        Category(id: "places", symbol: "airplane", title: Strings.Reactions.places, emoji: places),
        Category(id: "objects", symbol: "lightbulb", title: Strings.Reactions.objects, emoji: objects),
        Category(id: "symbols", symbol: "number", title: Strings.Reactions.symbols, emoji: symbols)
    ]

    static let smileys = [
        "😀", "😃", "😄", "😁", "😆", "😅", "🤣", "😂", "🙂", "🙃",
        "😉", "😊", "😇", "🥰", "😍", "🤩", "😘", "😗", "😚", "😙",
        "😋", "😛", "😜", "🤪", "😝", "🤗", "🤭", "🤫", "🤔", "🤐",
        "😐", "😑", "😶", "😏", "😒", "🙄", "😬", "😮‍💨", "🤥", "😌",
        "😔", "😪", "🤤", "😴", "😷", "🤒", "🤕", "🤢", "🤮", "🥴",
        "😵", "🤯", "🤠", "🥳", "😎", "🤓", "🧐", "😕", "😟", "🙁",
        "😮", "😯", "😲", "😳", "🥺", "😦", "😧", "😨", "😰", "😥",
        "😢", "😭", "😱", "😖", "😣", "😞", "😓", "😩", "😫", "🥱",
        "😤", "😡", "😠", "🤬", "😈", "👿", "💀", "💩", "🤡", "👻",
        "👽", "🤖", "🎃", "😺", "😸", "😹", "😻", "😼", "🙈", "🙉", "🙊"
    ]

    static let gestures = [
        "👍", "👎", "👌", "🤌", "🤏", "✌️", "🤞", "🫰", "🤟", "🤘",
        "🤙", "👈", "👉", "👆", "👇", "☝️", "✋", "🤚", "🖐️", "🖖",
        "👋", "🤝", "🙏", "✍️", "💅", "🤳", "💪", "🦾", "🦿", "👏",
        "🙌", "🫶", "👐", "🤲", "🫡", "🤦", "🤷", "💁", "🙋", "🙇",
        "👀", "👄", "🧠", "🫀", "🦻", "👣", "🫂", "👶", "🧑", "👴"
    ]

    static let hearts = [
        "❤️", "🧡", "💛", "💚", "💙", "💜", "🖤", "🤍", "🤎", "💔",
        "❣️", "💕", "💞", "💓", "💗", "💖", "💘", "💝", "💟", "♥️",
        "💋", "🔥", "✨", "⭐️", "🌟", "💫", "💥", "💢", "💦", "💨"
    ]

    static let animals = [
        "🐶", "🐱", "🐭", "🐹", "🐰", "🦊", "🐻", "🐼", "🐨", "🐯",
        "🦁", "🐮", "🐷", "🐸", "🐵", "🙊", "🐔", "🐧", "🐦", "🐤",
        "🦆", "🦅", "🦉", "🦇", "🐺", "🐗", "🐴", "🦄", "🐝", "🐛",
        "🦋", "🐌", "🐞", "🐜", "🕷️", "🦂", "🐢", "🐍", "🦎", "🐙",
        "🦑", "🦐", "🦞", "🦀", "🐡", "🐠", "🐟", "🐬", "🐳", "🦈",
        "🐊", "🐅", "🦓", "🦍", "🐘", "🦛", "🐪", "🦒", "🐄", "🐑",
        "🐕", "🐈", "🐓", "🦜", "🦩", "🌱", "🌲", "🌳", "🌴", "🌵",
        "🍀", "🍁", "🍂", "🍃", "🌷", "🌹", "🌺", "🌻", "🌼", "🌸"
    ]

    static let food = [
        "🍏", "🍎", "🍐", "🍊", "🍋", "🍌", "🍉", "🍇", "🍓", "🫐",
        "🍈", "🍒", "🍑", "🥭", "🍍", "🥥", "🥝", "🍅", "🍆", "🥑",
        "🥦", "🥬", "🥒", "🌶️", "🌽", "🥕", "🧄", "🧅", "🥔", "🍠",
        "🥐", "🍞", "🥖", "🧀", "🥚", "🍳", "🥞", "🧇", "🥓", "🍔",
        "🍟", "🍕", "🌭", "🥪", "🌮", "🌯", "🥙", "🧆", "🥘", "🍝",
        "🍜", "🍲", "🍣", "🍱", "🥟", "🍤", "🍙", "🍚", "🍥", "🥠",
        "🍦", "🍩", "🍪", "🎂", "🍰", "🧁", "🥧", "🍫", "🍬", "🍭",
        "🍯", "🥛", "☕️", "🍵", "🧃", "🥤", "🍺", "🍻", "🥂", "🍷",
        "🥃", "🍸", "🍾", "🧊"
    ]

    static let activity = [
        "⚽️", "🏀", "🏈", "⚾️", "🎾", "🏐", "🏉", "🎱", "🏓", "🏸",
        "🥅", "⛳️", "🏹", "🎣", "🥊", "🥋", "⛸️", "🎿", "🛷", "🏂",
        "🏋️", "🤸", "🤼", "🤽", "🤾", "🚴", "🚵", "🏇", "🧘", "🏄",
        "🏊", "🤺", "🎯", "🎳", "🎮", "🕹️", "🎲", "🧩", "🎭", "🎨",
        "🎬", "🎤", "🎧", "🎼", "🎹", "🥁", "🎷", "🎺", "🎸", "🎻",
        "🏆", "🥇", "🥈", "🥉", "🎖️", "🏅", "🎗️", "🎟️", "🎫", "🎉",
        "🎊", "🎈", "🎁", "🎀", "🪄", "🧨"
    ]

    static let places = [
        "🚗", "🚕", "🚙", "🚌", "🚎", "🏎️", "🚓", "🚑", "🚒", "🚚",
        "🚜", "🛵", "🏍️", "🚲", "🛴", "🛹", "🚂", "🚆", "🚇", "🚊",
        "✈️", "🛫", "🛬", "🚀", "🛸", "🚁", "⛵️", "🚤", "🛳️", "⚓️",
        "🗺️", "🧭", "🏔️", "🌋", "🏕️", "🏖️", "🏜️", "🏝️", "🏞️", "🏟️",
        "🏛️", "🏗️", "🏠", "🏢", "🏥", "🏦", "🏨", "🏫", "⛪️", "🕌",
        "🗽", "🗼", "🏰", "🌁", "🌃", "🌆", "🌇", "🌉", "🌌", "🌍",
        "🌎", "🌏", "🌐", "🌙", "☀️", "⛅️", "☁️", "🌧️", "⛈️", "❄️",
        "☃️", "🌈", "🌊"
    ]

    static let objects = [
        "⌚️", "📱", "💻", "⌨️", "🖥️", "🖨️", "🖱️", "💾", "💿", "📷",
        "🎥", "📺", "📻", "🎙️", "⏰", "⏳", "🔋", "🔌", "💡", "🔦",
        "🕯️", "🧯", "🛢️", "💸", "💵", "💳", "🧾", "💎", "⚖️", "🔧",
        "🔨", "⚒️", "🛠️", "⛏️", "🔩", "⚙️", "🧲", "🔫", "💣", "🔪",
        "🗡️", "🛡️", "🚬", "⚰️", "🏺", "🔮", "🧿", "🪬", "💈", "🔭",
        "🔬", "🕳️", "💊", "💉", "🩸", "🧬", "🦠", "🧫", "🧪", "🌡️",
        "🧹", "🧺", "🧻", "🚽", "🚿", "🛁", "🧼", "🪒", "🧴", "🔑",
        "🗝️", "🚪", "🛋️", "🛏️", "🧸", "🖼️", "🛍️", "🎒", "👑", "👓",
        "📚", "📖", "📝", "✏️", "📌", "📎", "📅", "📈", "📉", "📊",
        "📦", "✉️", "📧", "📮", "🔒", "🔓"
    ]

    static let symbols = [
        "✅", "❌", "⭕️", "❗️", "❓", "‼️", "⁉️", "💯", "🔴", "🟠",
        "🟡", "🟢", "🔵", "🟣", "⚫️", "⚪️", "🟤", "🔺", "🔻", "🔶",
        "🔷", "🔸", "🔹", "▶️", "⏸️", "⏹️", "⏺️", "⏭️", "⏮️", "🔀",
        "🔁", "🔂", "🔼", "🔽", "➕", "➖", "➗", "✖️", "♾️", "💲",
        "™️", "©️", "®️", "〰️", "➰", "➿", "🔚", "🔙", "🔛", "🔝",
        "🔜", "⚠️", "🚫", "⛔️", "📵", "🔞", "☢️", "☣️", "♻️", "🆗",
        "🆒", "🆕", "🆓", "🔔", "🔕", "🎵", "🎶", "💤", "🏳️", "🏴",
        "🏁", "🚩"
    ]
}

/// The emoji this person has reached for lately, so the second time is quicker than the first.
///
/// Kept in `@AppStorage` as one string with spaces between, which is the whole of the storage
/// format and is chosen for a reason: a reaction is a character or two, the list is capped at a
/// row and a half of them, and a `Codable` blob in `UserDefaults` for that would be ceremony
/// around nothing. A space can never appear *inside* an emoji, so splitting on it is safe.
///
/// Most recent first, no duplicates: sending 👍 for the twentieth time should not push the other
/// nineteen things you have ever sent off the end of the list.
struct RecentEmoji {
    static let storageKey = "reactions.recent"

    /// Twelve: the bar of six above the menu, twice over, and drawn as two rows of six so it
    /// reads as exactly that.
    ///
    /// Long enough to be worth having, short enough that it stays a *shortcut* rather than a
    /// second catalogue — and a number with a shape, which sixteen is not. Sixteen came out as
    /// two and a half ragged rows in a grid sized for the panel, and a ragged first row is the
    /// one thing in the picker the eye cannot skim.
    static let limit = 12

    static func list(from stored: String) -> [String] {
        stored.split(separator: " ").map(String.init)
    }

    static func adding(_ emoji: String, to stored: String) -> String {
        var list = list(from: stored).filter { $0 != emoji }
        list.insert(emoji, at: 0)
        return list.prefix(limit).joined(separator: " ")
    }
}
