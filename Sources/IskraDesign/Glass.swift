import SwiftUI

/// Liquid Glass, applied the way Apple asks for it.
///
/// The Human Interface Guidelines are unusually blunt about this material, and the
/// rules are easy to break by accident, so they are encoded here rather than left to
/// memory:
///
/// - **Glass belongs to the navigation layer.** Toolbars, tab bars, floating
///   controls, popovers. It does *not* belong on content. A message bubble is
///   content, so bubbles in this app are opaque fills — see `BubbleBackground`.
/// - **Never put glass on glass.** The material is defined by what it refracts; a
///   sheet of it over another sheet just turns to soup. `GlassEffectContainer`
///   exists so that several glass elements sitting near each other blend into one
///   surface instead of stacking.
/// - **Tint sparingly.** A tint marks the one primary action, not every control.
///
/// The naming is deliberate: there is no general-purpose `.glass()` here. You reach
/// for `.navigationGlass()`, and if that name feels wrong where you are about to put
/// it, that is the guideline talking.
public extension View {
    /// A floating navigation-layer surface: a toolbar, a composer bar, a control
    /// that hovers above scrolling content.
    func navigationGlass(in shape: some Shape = .capsule) -> some View {
        glassEffect(.regular, in: shape)
    }

    /// The one control on screen that is the point of the screen — "Continue" on
    /// sign-in, "Send" in the composer. Tinted so it reads as primary, and
    /// interactive so it responds to touch the way system glass does.
    func primaryActionGlass(tint: Color, in shape: some Shape = .capsule) -> some View {
        glassEffect(.regular.tint(tint).interactive(), in: shape)
    }
}
