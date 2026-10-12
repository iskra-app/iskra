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

    /// Whether the accent is washed across the *whole interface* — every screen's background, the
    /// words on it, the message bubbles, the chrome — rather than spent only on the content that is
    /// already the user's.
    ///
    /// It is a second key and not a ninth colour, because it is a second question. The accent
    /// answers "what colour is this app"; this answers "how far it spreads", and the two are chosen
    /// independently — the same green can be a green send button on a plain page or a room bathed in
    /// green throughout, and neither is a different colour.
    ///
    /// **Off by default, and that is an opinion, not an oversight.** A colour laid over everything is
    /// a colour that emphasises nothing: once the page, the words and the bubbles are all the same
    /// green, the message you just sent no longer stands out as yours. So the app stays plain unless
    /// somebody asks for this, and spends the accent only where it means something. See the wash in
    /// `IskraRootView`.
    public static let tintsInterfaceKey = "appearance.tintsInterface"

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

    /// The same pair as `foreground`, with the mono case spelled out instead of named.
    ///
    /// `.background` is a *contextual* style: it means "the background of the thing this is being
    /// drawn into", and it is resolved by whatever the label is sitting on. On an opaque bubble that
    /// is the page, and it comes out the right way round. Inside a Liquid Glass button it is *the
    /// glass* — so a mono label asking for `.background` was drawn in the colour of the pill it was
    /// written on, and the sign-in button came out blank. A shape style cannot see the colour scheme
    /// on its own, so the scheme is handed in and the black/white pair is chosen here.
    public func foreground(in scheme: ColorScheme) -> AnyShapeStyle {
        switch self {
        case .mono: AnyShapeStyle(scheme == .dark ? Color.black : Color.white)
        default: foreground
        }
    }

    /// The colour a *system control* fills itself with when it is on: the track of a switch, the
    /// bar of a slider, the tick in a checkbox.
    ///
    /// Not `color`, and the difference only matters on mono — but there it matters completely.
    /// `.primary` is the pair black/white, so a switch tinted with it is a white track in the dark
    /// and a black one in the light, and the knob the system draws on top of that is white in both.
    /// White on white is a switch with no visible state: it moves, and nothing about it changes.
    /// That is the bug this exists to fix, and it was not confined to the appearance screen — every
    /// switch in the app inherits the root tint, which is `.primary` whenever the interface is not
    /// tinted.
    ///
    /// So mono gives a control a *grey*, drawn from the same black/white pair and pulled far enough
    /// off it that the knob still reads: a deep grey under a white knob in the light, a soft one in
    /// the dark. The seven colours need none of this — a switch tinted red is a red switch — and get
    /// the accent itself.
    public func control(in scheme: ColorScheme) -> Color {
        switch self {
        case .mono: if scheme == .dark { Color.white.opacity(0.38) } else { Color.black.opacity(0.72) }
        default: color
        }
    }

    /// How much of the accent is washed over the app when "tint the interface" is on.
    ///
    /// Mono is washed more faintly than a colour, and this is the whole of what used to be a
    /// *refusal*. The switch was disabled on mono, on the argument that `.primary` is the
    /// foreground colour and a wash of it greys the app rather than tinting it. The observation is
    /// right and the conclusion was wrong: greying the app is exactly what a black-and-white theme
    /// spreading across the interface *is*, and a user who picks the colourless theme and then asks
    /// for it everywhere has asked for something perfectly coherent. What it needs is not a veto
    /// but a lighter hand — at eight percent the mono wash starts eating the words it is laid over,
    /// because unlike a colour it has no hue to spend, only darkness.
    public var washOpacity: Double {
        switch self {
        case .mono: Theme.Tint.mono
        default: Theme.Tint.interface
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
        bubble(onWallpaper: false)
    }

    /// The same fill, told whether there is a wallpaper behind it.
    ///
    /// Only mono has an answer that changes, and it has to: the seven colours fill a bubble with an
    /// opaque colour already, while mono fills it with sixteen percent of the foreground — a
    /// translucency, which over a photograph is the photograph. See `Color.ownBubbleOnWallpaper`.
    public func bubble(onWallpaper: Bool) -> AnyShapeStyle {
        switch self {
        case .mono: AnyShapeStyle(onWallpaper ? Color.ownBubbleOnWallpaper : Color.primary.opacity(0.16))
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
