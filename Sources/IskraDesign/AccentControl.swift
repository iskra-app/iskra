import SwiftUI

/// What a switch, a slider or a stepper is painted in.
///
/// Every one of them in this app used to be painted in the *root tint*, and the root tint is
/// `.primary` unless the user has asked for the interface to be tinted (`IskraRootView`) — which is
/// deliberate for the chrome and disastrous for a control that says something by filling itself in.
/// `.primary` is the pair black/white, so a switch that was on drew a white track in the dark
/// appearance and the system drew its white knob on top of it: a switch with no visible state,
/// reported, correctly, as "the toggles are just white".
///
/// The appearance screen had already noticed this and tinted its own two switches by hand. That is
/// the right answer and the wrong place for it: a rule that lives at three call sites is a rule the
/// fourth switch does not know about, and there were five others — the lock, the bridge, the room's
/// privacy, a new conversation's, the recovery code's acknowledgement — all of them white on white.
///
/// So it is one modifier, and it takes the colour from the accent rather than from the tint:
/// `AccentTheme.control(in:)`, which is the accent itself for the seven colours and a legible grey
/// for the colourless theme, where the accent *is* the foreground colour and cannot be a fill.
private struct AccentControl: ViewModifier {
    @Environment(\.accent) private var accent
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content.tint(accent.control(in: scheme))
    }
}

public extension View {
    /// Paints a switch, a slider or a stepper in the accent — and, on the colourless theme, in a
    /// grey that can actually be seen. Put it on every one of them; see `AccentControl`.
    func accentControl() -> some View {
        modifier(AccentControl())
    }
}
