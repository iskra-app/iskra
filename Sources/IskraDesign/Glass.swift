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
///   sheet of it over another sheet just turns to soup. `NavigationGlassGroup`
///   exists so that several glass elements sitting near each other blend into one
///   surface instead of stacking.
/// - **Tint sparingly.** A tint marks the one primary action, not every control.
///
/// The naming is deliberate: there is no general-purpose `.glass()` here. You reach
/// for `.navigationGlass()`, and if that name feels wrong where you are about to put
/// it, that is the guideline talking.
///
/// **This file is also the only place that knows glass is OS 26.** The app runs on
/// iOS 18 and macOS 15, where there is no such material, and every piece of glass in
/// it reaches the system through one of the functions below — so the `#available`
/// is written here, once each, and never in a view. On the older systems the
/// navigation layer is drawn the way it was before glass: a system material where
/// glass floats, the accent as a solid fill where glass is tinted, and the things
/// that only make sense *between* sheets of glass (morphing, the shared toolbar
/// capsule, the scroll edge effect) simply do nothing. A view that calls
/// `glassEffect` directly takes that decision back into itself, and the build for
/// the older systems is what says so.
public extension View {
    /// A floating navigation-layer surface: a toolbar, a composer bar, a control
    /// that hovers above scrolling content.
    @ViewBuilder
    func navigationGlass(in shape: some Shape = .capsule) -> some View {
        if #available(iOS 26, macOS 26, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(.regularMaterial, in: shape)
        }
    }

    /// The one control on screen that is the point of the screen — "Continue" on
    /// sign-in, "Send" in the composer. Tinted so it reads as primary, and
    /// interactive so it responds to touch the way system glass does.
    ///
    /// Before glass, the accent itself: the same fill `.primaryAction` draws, so the
    /// words `AccentTheme.foreground(in:)` puts on it stay readable.
    @ViewBuilder
    func primaryActionGlass(tint: Color, in shape: some Shape = .capsule) -> some View {
        if #available(iOS 26, macOS 26, *) {
            glassEffect(.regular.tint(tint).interactive(), in: shape)
        } else {
            background(tint, in: shape)
        }
    }

    /// Untinted glass behind a secondary action that has to stand beside a `.glassAction` — the
    /// same capsule, as tall, with the glass and nothing in it. See `GlassSecondaryStyle`.
    @ViewBuilder
    func secondaryActionGlass(in shape: some Shape = .capsule) -> some View {
        if #available(iOS 26, macOS 26, *) {
            glassEffect(.regular.interactive(), in: shape)
        } else {
            background(.quaternary, in: shape)
        }
    }

    /// The system's untinted glass button, for the secondary actions on a screen that
    /// is itself navigation — "Create account" beside "Continue", a close button over a
    /// sheet. Before glass, a bordered capsule, which is what that button was.
    @ViewBuilder
    func navigationGlassButton() -> some View {
        if #available(iOS 26, macOS 26, *) {
            buttonStyle(.glass)
        } else {
            buttonStyle(.bordered).buttonBorderShape(.capsule)
        }
    }

    /// Names a piece of glass inside a `NavigationGlassGroup`, so that it morphs into
    /// its neighbours as it appears and goes rather than fading. Before glass there is
    /// nothing to morph, and the view's own transition is all there is.
    @ViewBuilder
    func navigationGlassID(_ id: some Hashable & Sendable, in namespace: Namespace.ID) -> some View {
        if #available(iOS 26, macOS 26, *) {
            glassEffectID(id, in: namespace)
        } else {
            self
        }
    }

    /// The soft fade where scrolling content meets a glass toolbar. There is no such
    /// edge before glass — the bar draws its own background — so there it is nothing.
    @ViewBuilder
    func softScrollEdge(for edges: Edge.Set) -> some View {
        if #available(iOS 26, macOS 26, *) {
            scrollEdgeEffectStyle(.soft, for: edges)
        } else {
            self
        }
    }

    /// Hides the scroll edge effect while something (a portrait under the bar) should
    /// be seen clearly. Nothing to hide before glass.
    @ViewBuilder
    func scrollEdgeHidden(_ isHidden: Bool, for edges: Edge.Set) -> some View {
        if #available(iOS 26, macOS 26, *) {
            scrollEdgeEffectHidden(isHidden, for: edges)
        } else {
            self
        }
    }
}

/// Several pieces of glass that sit near each other, drawn as one surface instead of
/// sheets stacked into soup — and, with `navigationGlassID`, interpolated into each
/// other as they come and go. Before glass, just its content.
public struct NavigationGlassGroup<Content: View>: View {
    private let spacing: CGFloat
    private let content: Content

    public init(spacing: CGFloat, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    public var body: some View {
        if #available(iOS 26, macOS 26, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

public extension ButtonRole {
    /// The way out of a screen: the system's close button, with its look, placement and
    /// spoken label in every language. Before OS 26 there is no such role, and `.cancel`
    /// is the one that means the same thing to VoiceOver and to a sheet.
    static var leaving: ButtonRole {
        if #available(iOS 26, macOS 26, *) { .close } else { .cancel }
    }
}

public extension ToolbarContent {
    /// Takes a toolbar item out of the capsule of glass the system draws around a
    /// toolbar's items, for an item that is not a control (a title) or that carries
    /// glass of its own (a round avatar). Before glass there is no shared capsule to
    /// leave.
    func outsideToolbarGlass() -> some ToolbarContent {
        OutsideToolbarGlass(content: self)
    }
}

/// A gap between two toolbar items, so that each gets a capsule of glass of its own instead of
/// sharing one. Before glass there is no capsule to split, and so no gap.
@MainActor
public func toolbarGlassGap(placement: ToolbarItemPlacement) -> some ToolbarContent {
    ToolbarGlassGap(placement: placement)
}

struct ToolbarGlassGap: ToolbarContent {
    let placement: ToolbarItemPlacement

    @ToolbarContentBuilder
    var body: some ToolbarContent {
        if #available(iOS 26, macOS 26, *) {
            ToolbarSpacer(.fixed, placement: placement)
        }
    }
}

/// The `if #available` lives in a type the other modules cannot see, and that is the point of it.
/// Written inline in the public function above, a Release build's cross-module optimisation
/// copied the body into `IskraFeatures`, where it named the opaque type of SwiftUI's
/// `ToolbarContentBuilder.buildLimitedAvailability` — a symbol SwiftUI does not export, so the
/// app failed to link in Release while Debug, which copies nothing, linked fine.
struct OutsideToolbarGlass<Content: ToolbarContent>: ToolbarContent {
    let content: Content

    @ToolbarContentBuilder
    var body: some ToolbarContent {
        if #available(iOS 26, macOS 26, *) {
            content.sharedBackgroundVisibility(.hidden)
        } else {
            content
        }
    }
}
