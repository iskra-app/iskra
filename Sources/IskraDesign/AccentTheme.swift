import SwiftUI

/// The colour the app is painted in: the seven colours of the rainbow, and a mono theme
/// that has none.
///
/// Not `Color.accentColor`. That one is fixed at build time — it comes from the asset
/// catalogue, and `.tint(_:)` does not change what it resolves to — so a colour the user
/// picks has to travel some other way. It travels in the environment (`\.accent`), which
/// is also what lets a bubble ask for the colour *and* for what stays legible on top of
/// it without either being passed down by hand.
public enum AccentTheme: String, CaseIterable, Identifiable, Sendable {
    case red, orange, yellow, green, cyan, blue, violet
    /// No colour at all: black on a white screen, white on a black one.
    case mono

    /// Blue, because that is what the app has always been and a fresh install should not
    /// look like someone has already been at the settings.
    public static let `default` = AccentTheme.blue

    /// Where the choice is kept. One key, read by the root of the app and written by the
    /// appearance screen; `@AppStorage` on both ends keeps them in step.
    public static let storageKey = "appearance.accent"

    public var id: String { rawValue }

    /// The system's own colours, not seven of ours. They already carry a light and a dark
    /// variant and an increased-contrast one, and matching Apple's red by eye would mean
    /// maintaining all three by hand.
    public var color: Color {
        switch self {
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .cyan: .cyan
        case .blue: .blue
        case .violet: .purple
        // `Color.primary` *is* the pair black/white, chosen by the system according to the
        // screen it is drawn on. So the mono theme follows the display into dark mode
        // without a second colour being defined anywhere.
        case .mono: .primary
        }
    }

    /// What stays readable on top of the accent — the words in your own bubble, the arrow
    /// in the send button.
    ///
    /// White, for six of the seven. Yellow is the exception and it is not a close call:
    /// white on yellow is the one combination on this list that cannot be read at all.
    /// And the mono accent is the *foreground* colour, so the only thing that can sit on
    /// it is the background one — white on black in the light, black on white in the dark,
    /// each the inverse of the other because both come from the same system pair.
    public var foreground: AnyShapeStyle {
        switch self {
        case .yellow: AnyShapeStyle(.black)
        case .mono: AnyShapeStyle(.background)
        default: AnyShapeStyle(.white)
        }
    }

    /// The fill behind a message you sent.
    ///
    /// The accent, for the seven colours. Not for mono: a bubble filled with `.primary` is a
    /// slab of pure black on a white screen — a colour no colour scheme uses for a surface —
    /// and it turns a conversation into a page of dominoes. Grey is what the mono theme has
    /// instead, and it is a *deeper* grey than an incoming bubble rather than a different
    /// one, so the two still read as the same material with the sides told apart by weight.
    public var bubble: AnyShapeStyle {
        switch self {
        case .mono: AnyShapeStyle(Color.primary.opacity(0.16))
        default: AnyShapeStyle(color)
        }
    }

    /// The words in a message you sent. White on a colour; on mono's grey the ordinary text
    /// colour, because a grey light enough to read black on in the light is the same grey
    /// white reads on in the dark — which is exactly what `.primary` already means.
    public var onBubble: AnyShapeStyle {
        switch self {
        case .mono: AnyShapeStyle(.primary)
        default: foreground
        }
    }
}

public extension EnvironmentValues {
    /// The accent the user chose. Read it rather than `Color.accentColor` — see `AccentTheme`.
    @Entry var accent: AccentTheme = .default
}
