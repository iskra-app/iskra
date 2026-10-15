import SwiftUI

/// The one button on a screen that is the point of the screen: "Continue" on sign-in, "Try again"
/// on a room that would not load, "I have saved it" under a recovery code.
///
/// It exists because the system's prominent styles cannot be used here, and the reason is exact.
/// `.borderedProminent` and `.glassProminent` fill themselves with the **tint**, and the tint at the
/// root of this app is `.primary` (`IskraRootView`) — deliberately, so that the chrome stays
/// monochrome and the accent is spent only where it means something. `.primary` is the pair
/// black/white, so every prominent button that did not tint itself came out as a solid white slab in
/// the dark and a solid black one in the light, with a label the system drew in white on top of it.
/// A white label on a white pill is not a subtle contrast bug; it is a button with nothing written
/// on it, and there were eleven of them.
///
/// Tinting each site by hand — `.buttonStyle(.borderedProminent).tint(accent.color)` — was the
/// obvious repair, and it is the one this replaces. It fails on the mono theme, where the accent
/// *is* `.primary` and the slab comes straight back; and it is a rule that lives nowhere, so the
/// twelfth prominent button forgets it. So the fill and the words on it are drawn here, from the
/// same two properties a message bubble uses — `AccentTheme.color` and `AccentTheme.foreground`,
/// which is precisely the pair "the accent, and what stays readable on top of it". Mono comes out
/// black-on-white in the dark and white-on-black in the light, which is what a colourless accent
/// means; yellow comes out with black text, because white on yellow cannot be read at all.
///
/// Two styles rather than one, because the app has two layers and they are not interchangeable
/// (`Glass.swift`): `.glassAction` is for the navigation layer — the sign-in and recovery screens,
/// which float over a background — and `.primaryAction` is opaque, for buttons standing in content.
public struct PrimaryActionStyle: ButtonStyle {
    public func makeBody(configuration: Configuration) -> some View {
        Face(configuration: configuration)
    }

    /// A nested view rather than the style itself, because `@Environment` in a `ButtonStyle` is read
    /// once and never again — the accent would be whatever it was when the button was first drawn,
    /// and changing the colour on the appearance screen would leave these behind.
    private struct Face: View {
        @Environment(\.accent) private var accent
        @Environment(\.colorScheme) private var scheme
        let configuration: Configuration
        @ScaledSize(Theme.Size.minimumTapTarget) private var height
        /// A disabled main button has to *look* it: the accent is the colour of "press me", and a
        /// button that cannot be pressed wearing it is a button people press and wonder about.
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.body.weight(.semibold))
                .foregroundStyle(isEnabled ? accent.foreground(in: scheme) : AnyShapeStyle(.secondary))
                .padding(.horizontal, Theme.Spacing.roomy)
                .padding(.vertical, Theme.Spacing.close)
                .frame(minHeight: height)
                .background(isEnabled ? AnyShapeStyle(accent.color) : AnyShapeStyle(.quaternary), in: .capsule)
                .pressed(configuration.isPressed)
        }
    }
}

public struct GlassActionStyle: ButtonStyle {
    public func makeBody(configuration: Configuration) -> some View {
        Face(configuration: configuration)
    }

    private struct Face: View {
        @Environment(\.accent) private var accent
        @Environment(\.colorScheme) private var scheme
        let configuration: Configuration
        @ScaledSize(Theme.Size.minimumTapTarget) private var height
        /// See `PrimaryActionStyle`: disabled, it is untinted glass and grey words.
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            let face = configuration.label
                .font(.body.weight(.semibold))
                .foregroundStyle(isEnabled ? accent.foreground(in: scheme) : AnyShapeStyle(.secondary))
                .padding(.horizontal, Theme.Spacing.roomy)
                .padding(.vertical, Theme.Spacing.close)
                .frame(minHeight: height)
            // The glass is already interactive — it responds to a touch by itself — so this one
            // does not take the press scale on top of that.
            if isEnabled {
                face.primaryActionGlass(tint: accent.color)
            } else {
                face.secondaryActionGlass()
            }
        }
    }
}

/// The second button beside a `.glassAction` — "Choose a server" under "Next", "Create account"
/// under "Sign in". The system's `.glass` button is its own size, a few points shorter than this
/// app's main one, and two buttons stacked one under the other at two different heights read as
/// two different kinds of thing. This is the main one's shape and height, in untinted glass.
public struct GlassSecondaryStyle: ButtonStyle {
    public func makeBody(configuration: Configuration) -> some View {
        Face(configuration: configuration)
    }

    private struct Face: View {
        let configuration: Configuration
        @ScaledSize(Theme.Size.minimumTapTarget) private var height
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.body.weight(.semibold))
                .foregroundStyle(isEnabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                .padding(.horizontal, Theme.Spacing.roomy)
                .padding(.vertical, Theme.Spacing.close)
                .frame(minHeight: height)
                .secondaryActionGlass()
        }
    }
}

/// The two answers to a question the app is asking: yes in green, no in red.
///
/// The one place in this app where a button's colour is *not* the accent, and it is allowed to
/// be for the same reason a traffic light is allowed to be: green and red here are not decoration
/// and not branding, they are the two answers themselves. An invitation is the only screen that
/// asks a question with two equally real answers side by side — everywhere else there is one
/// action and a way back — and a pair of identical grey capsules makes the reader stop and read
/// both before answering something they had already decided about.
///
/// The two are drawn by one style with a colour passed in, so they cannot drift apart: same
/// height, same padding, same weight, same corner. Width is each button's own — they are the size
/// of the words on them — and that is what carries the equality now that the capsules are no
/// longer stretched across half a row each. See `InviteRow`.
///
/// The capsule is drawn *inside* a tap target rather than being one. It is set in subheadline with
/// four points above and below, which comes out around twenty-eight tall — a control that belongs
/// under a line of secondary text in a list, not a pair of slabs the size of a sign-in button. The
/// `minHeight` then sits outside the fill, so what the finger has to hit is still the full
/// forty-four points the HIG asks for while what the eye sees is small. Putting the background
/// after the frame, which is how this used to read, made the capsule itself forty-four tall and
/// there was no way to shrink one without shrinking the other.
///
/// White on both, in both appearances, rather than `AccentTheme.foreground`: these fills are
/// fixed colours and not the accent, and white is readable on both of them light and dark.
public struct AnswerStyle: ButtonStyle {
    public enum Answer {
        case accepting
        case declining

        /// Deeper than the system's `.green` and `.red`, and on purpose: the words on these are
        /// white, and white on system green is about 2.2:1 — a button whose label half the people
        /// holding the phone in the sun cannot read. These two hold 4.5:1 or better (about 5.2 and
        /// 5.7), the line WCAG draws for text this size, and are still the green and the red
        /// everybody reads as yes and no.
        var color: Color {
            switch self {
            case .accepting: Color(red: 0.11, green: 0.49, blue: 0.22)
            case .declining: Color(red: 0.77, green: 0.15, blue: 0.11)
            }
        }
    }

    let answer: Answer

    public func makeBody(configuration: Configuration) -> some View {
        Face(answer: answer, configuration: configuration)
    }

    private struct Face: View {
        let answer: Answer
        let configuration: Configuration
        @ScaledSize(Theme.Size.minimumTapTarget) private var height

        var body: some View {
            configuration.label
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, Theme.Spacing.normal)
                .padding(.vertical, Theme.Spacing.tight)
                .background(answer.color, in: .capsule)
                .pressed(configuration.isPressed)
                // The target, around the capsule rather than under it. A shape this small is
                // still forty-four points to a finger; `contentShape` is what makes the empty
                // margin part of the button instead of a gap between two of them.
                .frame(minHeight: height)
                .contentShape(.rect)
        }
    }
}

public extension ButtonStyle where Self == AnswerStyle {
    /// Yes or no, in the two colours everybody already reads as yes and no — see `AnswerStyle`.
    static func answer(_ answer: AnswerStyle.Answer) -> AnswerStyle { AnswerStyle(answer: answer) }
}

private extension View {
    /// The press. Small, and on the whole button rather than on its label: a filled shape that
    /// dips is how the system's own prominent buttons answer a finger, and a label that moved
    /// inside a pill that did not would read as a bug.
    func pressed(_ isPressed: Bool) -> some View {
        scaleEffect(isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: Theme.Timing.chrome), value: isPressed)
    }
}

public extension ButtonStyle where Self == PrimaryActionStyle {
    /// The primary action, standing in content: opaque, filled with the accent.
    static var primaryAction: PrimaryActionStyle { PrimaryActionStyle() }
}

public extension ButtonStyle where Self == GlassActionStyle {
    /// The primary action on the navigation layer — sign-in, recovery — where the app is glass.
    static var glassAction: GlassActionStyle { GlassActionStyle() }
    static var glassSecondary: GlassSecondaryStyle { GlassSecondaryStyle() }
}
