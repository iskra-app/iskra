import SwiftUI

/// A `Theme` size that grows with the reader's text size — and stops growing before it breaks the
/// screen it is on.
///
/// Dynamic Type is not a preference, it is how a great many people use their phone at all, and the
/// app was ignoring it: `@ScaledMetric` appeared nowhere, so every fixed measurement in the app
/// stayed exactly where it was while the text inside it grew. At the accessibility sizes that is
/// two to three times larger. The round buttons in the composer are 44pt and hold a symbol that
/// scales with the font, so the symbol outgrew the button. The search field is 44pt tall and holds
/// a line of text that outgrew it. The avatar beside a message is 28pt and stands next to a name
/// that ends up twice its height.
///
/// The cap is the part worth explaining, because scaling *without* one would be its own bug. At the
/// largest accessibility size the system's factor is a little over three, and an avatar three times
/// larger does not make a message easier to read — it pushes the message off the side of the
/// screen. Text may take all the room it needs; the furniture around it takes some and then stops.
/// 1.6 is enough that a 44pt control clears the 70pt its own glyph reaches at AX5, and little enough
/// that a row is still a row.
///
/// Relative to `.body`, because that is the size of the text these things stand beside.
@propertyWrapper
public struct ScaledSize: DynamicProperty {
    @ScaledMetric(relativeTo: .body) private var factor: CGFloat = 1

    private let base: CGFloat
    private let limit: CGFloat

    public init(_ base: CGFloat, upTo limit: CGFloat = 1.6) {
        self.base = base
        self.limit = limit
    }

    public var wrappedValue: CGFloat {
        base * min(factor, limit)
    }
}

/// The same idea for a view that is *handed* its size instead of declaring one.
///
/// `Avatar` is given a diameter by every caller — 28 beside a message, 56 in the chat list, 64 in
/// settings — so there is no constant for a property wrapper to wrap. This reads the same scale and
/// the caller multiplies by it.
@propertyWrapper
public struct TextScale: DynamicProperty {
    @ScaledMetric(relativeTo: .body) private var factor: CGFloat = 1

    private let limit: CGFloat

    public init(upTo limit: CGFloat = 1.6) {
        self.limit = limit
    }

    public var wrappedValue: CGFloat {
        min(factor, limit)
    }
}
