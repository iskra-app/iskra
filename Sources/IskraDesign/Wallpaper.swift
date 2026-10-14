import SwiftUI

/// What is behind a conversation.
///
/// Nothing, by default, and that is the honest starting point: a chat is words, and the page they
/// are written on should get out of the way. But the page a conversation happens on is the one
/// surface in a messenger that is nobody's message and everybody's — it is the room itself — and
/// making it yours is the oldest customisation there is.
///
/// Eight choices and no more: no wallpaper, six gradients, and a photograph of the user's own. The
/// gradients are gradients rather than pictures on purpose. A shipped photograph is somebody else's
/// photograph — it dates, it weighs a megabyte in the bundle, and it competes with the messages in
/// front of it — while two colours blending over a screen cost nothing to carry, resize to any
/// window on any platform, and are quiet enough to write on. The one picture that is worth putting
/// behind a conversation is one the user chose, and that is what `.photo` is.
///
/// The choice is one setting for the whole app rather than one per room. That is a decision and not
/// a limitation: a wallpaper is how *this app* looks to the person using it, the way the accent is,
/// and eight rooms with eight backgrounds is a different app in every conversation.
public enum Wallpaper: String, CaseIterable, Identifiable, Sendable {
    /// The app's own background, and the default. The conversation sits on the page every other
    /// screen sits on.
    case none

    case sunset, sea, forest, dusk, sand, night

    /// A picture from the user's library, kept on this device — see `WallpaperStore`, which is
    /// where the bytes live.
    case photo

    public static let `default` = Wallpaper.none

    /// Where the choice is kept, read by every room and written by the appearance screen.
    public static let storageKey = "appearance.wallpaper"

    /// How far down the wallpaper is taken, 0 to `maximumDimming`. A separate key because it is a
    /// separate question: which picture, and how loudly.
    public static let dimmingKey = "appearance.wallpaperDimming"

    /// Enough to take a bright photograph down to something a grey bubble reads on, and not so far
    /// that the choice becomes a black screen with a rumour of a picture behind it.
    public static let maximumDimming: Double = 0.8

    /// A quarter. A gradient needs none of it and a photograph usually needs some, and starting at
    /// zero means the first thing a user sees after picking their own picture is the version of it
    /// that is hardest to read — which reads as the app having no answer rather than as a slider
    /// they have not moved yet.
    public static let defaultDimming: Double = 0.25

    public var id: String { rawValue }

    /// Whether anything is drawn behind the conversation at all.
    public var isSet: Bool { self != .none }

    /// How bright the gradient is, 0 to 1 — the mean of its two colours' relative luminance. Nil
    /// for the photograph, whose brightness has to be measured (`WallpaperStore.luminance`), and
    /// for no wallpaper at all.
    public var luminance: Double? {
        let values = components
        guard !values.isEmpty else { return nil }
        return values.map { Self.luminance(red: $0[0], green: $0[1], blue: $0[2]) }.reduce(0, +) / Double(values.count)
    }

    /// The colour at the top of the gradient once the dimmer has gone over it — what something that
    /// fades into the wallpaper at the top of the screen fades into. Nil for the photograph, which
    /// has no one colour, and for no wallpaper at all.
    public func topColor(dimming: Double) -> Color? {
        guard let top = components.first else { return nil }
        let keep = 1 - dimming
        return Color(red: top[0] * keep, green: top[1] * keep, blue: top[2] * keep)
    }

    /// Relative luminance of an sRGB colour, as WCAG defines it.
    public static func luminance(red: Double, green: Double, blue: Double) -> Double {
        func linear(_ channel: Double) -> Double {
            channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// Whether words on this wallpaper should be light. Measured after the dimmer, which only
    /// ever darkens. The threshold is where white and black text have the same contrast (WCAG):
    /// below it white reads better, above it black does.
    public static func isDark(luminance: Double, dimming: Double) -> Bool {
        luminance * (1 - dimming) < 0.179
    }

    /// The two colours, top to bottom.
    ///
    /// Deliberately not the system's named colours. `.blue` and the rest are *control* colours —
    /// they are tuned to be pressed, they shift with increased contrast, and two of them side by
    /// side make a background that looks like a button someone stretched. These are fixed pairs,
    /// dark enough at the bottom that white chrome reads over them and soft enough at the top that
    /// they are a room rather than a poster.
    var colors: [Color] {
        components.map { Color(red: $0[0], green: $0[1], blue: $0[2]) }
    }

    /// The two colours as sRGB components, top to bottom — the one table the colours, their
    /// brightness and the top edge are all read from.
    private var components: [[Double]] {
        switch self {
        case .sunset: [[0.98, 0.55, 0.35], [0.54, 0.24, 0.47]]
        case .sea: [[0.36, 0.68, 0.86], [0.10, 0.28, 0.52]]
        case .forest: [[0.51, 0.74, 0.51], [0.11, 0.31, 0.27]]
        case .dusk: [[0.44, 0.45, 0.74], [0.16, 0.15, 0.33]]
        case .sand: [[0.93, 0.85, 0.70], [0.66, 0.51, 0.38]]
        case .night: [[0.22, 0.24, 0.30], [0.05, 0.05, 0.09]]
        case .none, .photo: []
        }
    }
}

/// The wallpaper, drawn.
///
/// It takes the custom picture from outside rather than loading it, because loading it means the
/// file system and the file system means the app's container — which is `IskraCore`'s business and
/// not this layer's. Here it is a gradient, a picture, and how dark to take it.
public struct WallpaperBackdrop: View {
    let wallpaper: Wallpaper
    /// The user's own picture, when they have chosen one. Nil while it is still being read off the
    /// disk, and nil for good if it will not read — in which case the conversation simply sits on
    /// the app's own page, which is exactly what it did before anybody chose anything.
    let photo: Image?
    let dimming: Double

    public init(wallpaper: Wallpaper, photo: Image?, dimming: Double) {
        self.wallpaper = wallpaper
        self.photo = photo
        self.dimming = dimming
    }

    public var body: some View {
        Group {
            switch wallpaper {
            case .none:
                EmptyView()

            case .photo:
                if let photo {
                    // Filled, not fitted: a wallpaper with a letterbox down two sides is not a
                    // wallpaper. The picture is clipped by the frame it is drawn into, which is
                    // the screen.
                    photo
                        .resizable()
                        .scaledToFill()
                }

            default:
                LinearGradient(colors: wallpaper.colors, startPoint: .top, endPoint: .bottom)
            }
        }
        // The dimmer, over the picture and under the conversation. Black rather than a scheme-aware
        // veil: "затемнение" is one direction, and a wallpaper the user finds too loud is never too
        // loud in the direction of *brighter*.
        .overlay {
            if wallpaper.isSet {
                Color.black.opacity(dimming)
            }
        }
        .clipped()
        .ignoresSafeArea()
        // Behind everything and reachable by nothing. A background that swallowed a touch meant for
        // the message on top of it would be the worst kind of bug to find.
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

public extension EnvironmentValues {
    /// Whether the conversation being drawn is standing on a wallpaper.
    ///
    /// Bubbles have to know. Their fills are *hierarchical* — five percent of the foreground colour
    /// for an incoming message, sixteen for your own on the colourless theme — which is exactly
    /// right on the app's own opaque page and falls apart over a photograph: five percent of black
    /// laid over somebody's holiday snap is the holiday snap, with words on it. So the bubble asks
    /// this, and over a wallpaper it uses an opaque fill instead. See `MessageBubble`.
    @Entry var hasWallpaper: Bool = false

    /// Whether the wallpaper under the conversation is dark — what words drawn straight onto it
    /// take their colour from (`onWallpaperInk()`). Meaningless without `hasWallpaper`.
    @Entry var wallpaperIsDark: Bool = true
}

public extension View {
    /// Words drawn straight onto the conversation, coloured so a wallpaper cannot swallow them:
    /// white on a dark one, near-black on a light one, each with a faint halo of the other for the
    /// busy parts of a photograph. Without a wallpaper, the secondary grey they have on the app's
    /// own page. In place of `.foregroundStyle(.secondary)` on the words themselves — a style set
    /// further out is overridden by one set closer in, so it cannot be put round them afterwards.
    ///
    /// The alternative to `wallpaperPlate()` for the smallest words — the time beside a bubble —
    /// where a capsule under every message is a row of pills down the screen.
    func onWallpaperInk() -> some View {
        modifier(OnWallpaperInk())
    }

    /// Something to stand on, for words drawn straight onto the conversation — the date between
    /// days, a line saying who joined, the time beside a bubble — when the conversation is standing
    /// on a wallpaper, and nothing when it is not.
    ///
    /// The bubbles already knew to go opaque over a wallpaper; these did not, and secondary grey
    /// over a dark photograph in the light appearance is words nobody can read. A capsule of
    /// material, the way every messenger with wallpapers does it. A material, not glass: this is
    /// content, and glass stays on the navigation layer (see `Glass.swift`).
    func wallpaperPlate() -> some View {
        modifier(WallpaperPlate())
    }
}

private struct OnWallpaperInk: ViewModifier {
    @Environment(\.hasWallpaper) private var hasWallpaper
    @Environment(\.wallpaperIsDark) private var isDark

    func body(content: Content) -> some View {
        if hasWallpaper {
            content
                .foregroundStyle(isDark ? Color.white.opacity(0.92) : Color.black.opacity(0.78))
                .shadow(color: (isDark ? Color.black : Color.white).opacity(0.45), radius: 1.5)
        } else {
            content.foregroundStyle(.secondary)
        }
    }
}

private struct WallpaperPlate: ViewModifier {
    @Environment(\.hasWallpaper) private var hasWallpaper

    func body(content: Content) -> some View {
        if hasWallpaper {
            content
                .padding(.horizontal, Theme.Spacing.close)
                .padding(.vertical, Theme.Spacing.withinRun)
                .background(.regularMaterial, in: Capsule())
        } else {
            content
        }
    }
}
