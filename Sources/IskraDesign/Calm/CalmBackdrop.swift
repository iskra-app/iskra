import SwiftUI

/// What the glass in the calm look stands on: the ground, with a shade of one colour in it.
///
/// Each conversation has its own shade, worked out from its ID, so that a room looks the same every
/// time it is opened and two rooms can be told apart at a glance. Nobody's avatar goes behind the
/// words. With no seed it is the plain ground.
public struct CalmBackdrop: View {
    let seed: String?
    /// For settings and the screens like them — see `Theme.Calm.Form`.
    let isDimmed: Bool

    @Environment(\.colorScheme) private var scheme

    public init(seed: String?, isDimmed: Bool = false) {
        self.seed = seed
        self.isDimmed = isDimmed
    }

    public var body: some View {
        ZStack {
            Theme.Calm.ground
            if let seed {
                Self.shade(for: seed, in: scheme)
                    .opacity(scheme == .dark ? Theme.Calm.Shade.opacityDark : Theme.Calm.Shade.opacityLight)
            }
            if isDimmed {
                Color.black.opacity(scheme == .dark ? Theme.Calm.Form.pageDim : Theme.Calm.Form.pageDimLight)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// The colour of a seed's shade, before it is thinned for whatever it is laid on.
    public static func shade(for seed: String, in scheme: ColorScheme) -> Color {
        Color(hue: hue(for: seed),
              saturation: Theme.Calm.Shade.saturation,
              brightness: scheme == .dark ? Theme.Calm.Shade.brightnessDark : Theme.Calm.Shade.brightnessLight)
    }

    /// The hue of a seed, 0 to 1.
    static func hue(for seed: String) -> Double {
        Double(stableHash(seed) % 360) / 360
    }
}

/// FNV-1a over a string's bytes, because `String.hashValue` changes from one launch to the next and
/// neither a room's colour nor an emoji's tilt may.
func stableHash(_ seed: String) -> UInt64 {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in seed.utf8 {
        hash ^= UInt64(byte)
        hash &*= 0x0000_0100_0000_01b3
    }
    return hash
}

public extension EnvironmentValues {
    /// What the shade of the screen being drawn comes from, for the surfaces standing on it.
    @Entry var calmShadeSeed: String?
}

public extension View {
    /// A floating surface: the message menu, its emoji. Glass as anywhere else, and in the calm look
    /// glass with a little of the screen's shade in it, so that it belongs to the room behind it.
    func menuGlass(in shape: some Shape) -> some View {
        modifier(MenuGlass(shape: shape))
    }
}

private struct MenuGlass<S: Shape>: ViewModifier {
    let shape: S

    @Environment(\.design) private var design
    @Environment(\.calmShadeSeed) private var seed
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        switch design {
        case .classic:
            content.navigationGlass(in: shape)
        case .calm:
            content.contentGlass(in: shape,
                                 tint: seed.map {
                                     CalmBackdrop.shade(for: $0, in: scheme)
                                         .opacity(Theme.Calm.Shade.surfaceTint)
                                 })
        }
    }
}

/// The emoji under a message in the calm look: at the bubble's corner, half over its edge, at the
/// bottom right of somebody else's and the bottom left of your own.
///
/// Placed over the bubble, which is why it is a layout of its own: it takes the bubble's size as
/// its bounds and answers with that, so the bubble does not change shape, and it starts from the
/// corner and grows along the bottom edge. When there are more than the bubble is wide, it runs on
/// past the far edge, into the side of the row that is empty, and never off the screen.
public struct CalmReactionCluster: Layout {
    let isOwn: Bool

    public init(isOwn: Bool) {
        self.isOwn = isOwn
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews,
                              cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let gap = Theme.Spacing.tight
        let total = sizes.map(\.width).reduce(0, +) + gap * CGFloat(max(sizes.count - 1, 0))
        let inset = Theme.Calm.Reaction.edgeInset

        var x = isOwn ? min(bounds.minX + inset, bounds.maxX - total)
                      : max(bounds.maxX - inset, bounds.minX + total) - total
        for (subview, size) in zip(subviews, sizes) {
            subview.place(at: CGPoint(x: x, y: bounds.maxY + Theme.Calm.Reaction.overhang - size.height),
                          proposal: .unspecified)
            x += size.width + gap
        }
    }
}

/// A short fact in a capsule of glass: a date, "unread messages".
public struct CalmChip<Label: View>: View {
    private let label: Label

    public init(@ViewBuilder label: () -> Label) {
        self.label = label()
    }

    public var body: some View {
        label
            .font(.footnote.weight(.semibold).monospacedDigit())
            .lineLimit(1)
            .foregroundStyle(Theme.Calm.ink)
            .padding(.horizontal, Theme.Spacing.normal)
            .padding(.vertical, Theme.Spacing.close)
            .contentGlass(in: .capsule)
    }
}
