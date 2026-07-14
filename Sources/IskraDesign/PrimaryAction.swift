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

        var body: some View {
            configuration.label
                .font(.body.weight(.semibold))
                .foregroundStyle(accent.foreground(in: scheme))
                .padding(.horizontal, Theme.Spacing.roomy)
                .padding(.vertical, Theme.Spacing.close)
                .frame(minHeight: height)
                .background(accent.color, in: .capsule)
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

        var body: some View {
            configuration.label
                .font(.body.weight(.semibold))
                .foregroundStyle(accent.foreground(in: scheme))
                .padding(.horizontal, Theme.Spacing.roomy)
                .padding(.vertical, Theme.Spacing.close)
                .frame(minHeight: height)
                // The glass is already interactive — it responds to a touch by itself — so this one
                // does not take the press scale on top of that.
                .primaryActionGlass(tint: accent.color)
        }
    }
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
}
