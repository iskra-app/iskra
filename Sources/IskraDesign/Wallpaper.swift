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

    /// The two colours, top to bottom.
    ///
    /// Deliberately not the system's named colours. `.blue` and the rest are *control* colours —
    /// they are tuned to be pressed, they shift with increased contrast, and two of them side by
    /// side make a background that looks like a button someone stretched. These are fixed pairs,
    /// dark enough at the bottom that white chrome reads over them and soft enough at the top that
    /// they are a room rather than a poster.
    var colors: [Color] {
        switch self {
        case .sunset: [Color(red: 0.98, green: 0.55, blue: 0.35), Color(red: 0.54, green: 0.24, blue: 0.47)]
        case .sea: [Color(red: 0.36, green: 0.68, blue: 0.86), Color(red: 0.10, green: 0.28, blue: 0.52)]
        case .forest: [Color(red: 0.51, green: 0.74, blue: 0.51), Color(red: 0.11, green: 0.31, blue: 0.27)]
        case .dusk: [Color(red: 0.44, green: 0.45, blue: 0.74), Color(red: 0.16, green: 0.15, blue: 0.33)]
        case .sand: [Color(red: 0.93, green: 0.85, blue: 0.70), Color(red: 0.66, green: 0.51, blue: 0.38)]
        case .night: [Color(red: 0.22, green: 0.24, blue: 0.30), Color(red: 0.05, green: 0.05, blue: 0.09)]
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
}

public extension View {
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
