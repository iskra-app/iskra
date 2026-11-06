import SwiftUI

/// Which of the app's two looks is being drawn.
///
/// `.classic` is the app as it ships. `.calm` is «Штиль», the beta behind `BetaFeatures.calmDesignKey`:
/// monochrome, SF Rounded, and glass on everything — see `docs/DESIGN-CALM.md` for the whole of it.
/// It travels in the environment for the reason the accent does: the root reads the switch once, and
/// everything below asks without being passed anything.
///
/// Every place that draws differently branches on this, and the `.classic` branch stays the code it
/// always was, so with the switch off the app draws what it drew before.
public enum DesignLanguage: Sendable, Hashable {
    case classic
    case calm
}

public extension EnvironmentValues {
    @Entry var design: DesignLanguage = .classic

    /// The accent the person chose, for their own messages and the unread marks in the chat list.
    ///
    /// The same as `accent` in the classic look. In the calm one `accent` is `.mono`, so that every
    /// piece of chrome that asks for the accent comes out in ink without being told about a second
    /// design, and these two are what still has a colour.
    @Entry var bubbleAccent: AccentTheme = .default
}

public extension Theme {
    /// The numbers and colours of «Штиль», carried over from PhotoDump and adjusted — see
    /// `docs/DESIGN-CALM.md` for what changed and why.
    enum Calm {
        /// One colour in each appearance, kept as numbers so a test can hold them to a contrast.
        public struct Tone: Sendable {
            public let light: UInt32
            public let dark: UInt32

            public var color: Color {
                Color.adaptive(light: Self.color(light), dark: Self.color(dark))
            }

            /// Relative luminance, as WCAG defines it.
            public func luminance(dark isDark: Bool) -> Double {
                let hex = isDark ? dark : light
                return Wallpaper.luminance(red: Double((hex >> 16) & 0xFF) / 255,
                                           green: Double((hex >> 8) & 0xFF) / 255,
                                           blue: Double(hex & 0xFF) / 255)
            }

            private static func color(_ hex: UInt32) -> Color {
                Color(red: Double((hex >> 16) & 0xFF) / 255,
                      green: Double((hex >> 8) & 0xFF) / 255,
                      blue: Double(hex & 0xFF) / 255)
            }
        }

        public enum Tones {
            public static let ground = Tone(light: 0xF2F2EF, dark: 0x0C0C0D)
            public static let surface = Tone(light: 0xE7E7E3, dark: 0x19191B)
            public static let surfaceHigh = Tone(light: 0xDADAD5, dark: 0x252527)
            public static let ink = Tone(light: 0x111112, dark: 0xF2F2EF)
            /// PhotoDump's 6E6E72 comes out just under 4.5:1 on the ground in the light, a shade
            /// too faint for words that have glass under them as well.
            public static let inkSoft = Tone(light: 0x6A6A6E, dark: 0x8C8C91)
            public static let keep = Tone(light: 0xA6CC4E, dark: 0xC2E06A)
            public static let trash = Tone(light: 0xE65F4B, dark: 0xF07763)
            /// Coral as words. `trash` is a fill, about 3:1 against the ground in the light.
            public static let trashInk = Tone(light: 0xB83A28, dark: 0xF07763)
            /// What is written on `keep` and `trash`, in both appearances.
            public static let onAccent = Tone(light: 0x111112, dark: 0x111112)
        }

        public static var ground: Color { Tones.ground.color }
        public static var surface: Color { Tones.surface.color }
        public static var surfaceHigh: Color { Tones.surfaceHigh.color }
        public static var ink: Color { Tones.ink.color }
        public static var inkSoft: Color { Tones.inkSoft.color }
        /// Yes: join, accept. A fill, never words.
        public static var keep: Color { Tones.keep.color }
        /// No and trouble: decline, delete, failed to send. A fill, never words.
        public static var trash: Color { Tones.trash.color }
        public static var trashInk: Color { Tones.trashInk.color }
        public static var onAccent: Color { Tones.onAccent.color }

        /// The shade in the backdrop — see `CalmBackdrop`. Lighter and fainter in the light, where a
        /// little colour goes further.
        public enum Shade {
            public static let saturation: Double = 0.3
            public static let brightnessDark: Double = 0.45
            public static let brightnessLight: Double = 0.9
            public static let opacityDark: Double = 0.24
            public static let opacityLight: Double = 0.18
            /// How much of the shade goes into a surface on top of it: a settings row, the menu.
            public static let surfaceTint: Double = 0.35
            public static let surfaceSaturationDark: Double = 0.4
            public static let surfaceBrightnessDark: Double = 0.2
            public static let inkSaturationDark: Double = 0.08
            public static let inkBrightnessDark: Double = 0.96
            public static let inkSaturationLight: Double = 0.6
            public static let inkBrightnessLight: Double = 0.18
            /// The side of the small copy of an avatar its colour is read from. Big enough that a
            /// small object in the middle of the picture is still there.
            public static let sampleSide: Int = 32
            /// How much colour a pixel must have to have a say in the picture's colour.
            public static let leastColour: Double = 0.2
            /// How finely the colour wheel is cut when a picture's colour is voted on.
            public static let hueBuckets: Int = 24
        }

        /// How a conversation fades under the title bar and the composer — see `RoomView.timelineFade`.
        public enum Fade {
            public static let length: CGFloat = 96
            /// How much of a message is left at the end of the fade.
            public static let floor: Double = 0.25
        }

        /// The emoji under a message — see `CalmReactionCluster`.
        public enum Reaction {
            public static let circle: CGFloat = 28
            /// How far the first one stands in from the bubble's side.
            public static let edgeInset: CGFloat = 4
            /// How far below the bubble they reach, which the row keeps free for them. The rest of the
            /// circle, 8 points, lies on the bubble: less than its 12 of padding, so never on the words.
            public static let overhang: CGFloat = 20
            /// The most an emoji leans, either way.
            public static let maxTilt: Double = 14

            /// How far this emoji leans on this message. Looks random, and stays the same every time
            /// the message is drawn, or the emoji would shift on each redraw.
            public static func tilt(for seed: String) -> Double {
                let steps = Int(maxTilt) * 2 + 1
                return Double(Int(stableHash(seed) % UInt64(steps))) - maxTilt
            }
        }

        /// Settings and the screens like them: the page a little darker, so that the rows on it read
        /// as lying on top. The rows lifted by a thin layer of white.
        public enum Form {
            public static let pageDim: Double = 0.3
            public static let pageDimLight: Double = 0.05
            public static let rowLift: Double = 0.06
            public static let rowLiftLight: Double = 0.5
        }

        /// Your own bubble on the colourless accent: the same glass, a tone heavier.
        public static let monoBubbleTint: Double = 0.22
        /// A colour on your own bubble: thinned a little, or it stops looking like glass.
        public static let colourBubbleTint: Double = 0.75
    }
}

public extension AccentTheme {
    /// The tint of your own bubble's glass. A colour is its own tint; mono is ink, thinned, since
    /// a bubble of solid ink is the slab of dominoes `bubble` already refuses to draw.
    var calmBubbleTint: Color {
        switch self {
        case .mono: Theme.Calm.ink.opacity(Theme.Calm.monoBubbleTint)
        default: color.opacity(Theme.Calm.colourBubbleTint)
        }
    }

    /// The words on that glass.
    var calmOnBubble: AnyShapeStyle {
        switch self {
        case .mono: AnyShapeStyle(Theme.Calm.ink)
        default: foreground
        }
    }
}
