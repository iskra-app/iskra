import ImageIO
import SwiftUI

/// What the glass in the calm look stands on: the ground, with a shade of one colour in it.
///
/// A conversation takes the colour of its avatar; everything else, and a conversation with no colour
/// in its avatar, takes the shade worked out from the account's ID. Nobody's picture goes behind the
/// words. With no hue, which is also "tint the interface" switched off, it is the plain ground.
public struct CalmBackdrop: View {
    let hue: Double?
    /// For settings and the screens like them — see `Theme.Calm.Form`.
    let isDimmed: Bool

    @Environment(\.colorScheme) private var scheme

    public init(hue: Double?, isDimmed: Bool = false) {
        self.hue = hue
        self.isDimmed = isDimmed
    }

    public var body: some View {
        ZStack {
            Theme.Calm.ground
            if let hue {
                Self.shade(hue: hue, in: scheme)
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

    /// The colour of a shade, before it is thinned for whatever it is laid on.
    public static func shade(hue: Double, in scheme: ColorScheme) -> Color {
        Color(hue: hue,
              saturation: Theme.Calm.Shade.saturation,
              brightness: scheme == .dark ? Theme.Calm.Shade.brightnessDark : Theme.Calm.Shade.brightnessLight)
    }

    /// The same hue for a surface on top of the shade: a settings row, the menu. In the dark it is
    /// about as dark as the surface itself, so it colours the surface without lightening it.
    public static func surfaceShade(hue: Double, in scheme: ColorScheme) -> Color {
        guard scheme == .dark else { return shade(hue: hue, in: scheme) }
        return Color(hue: hue,
                     saturation: Theme.Calm.Shade.surfaceSaturationDark,
                     brightness: Theme.Calm.Shade.surfaceBrightnessDark)
    }

    /// The ink of words in a tinted conversation: nearly the plain ink, with a breath of the hue.
    public static func ink(hue: Double?, in scheme: ColorScheme) -> Color {
        guard let hue else { return Theme.Calm.ink }
        return scheme == .dark
            ? Color(hue: hue, saturation: Theme.Calm.Shade.inkSaturationDark, brightness: Theme.Calm.Shade.inkBrightnessDark)
            : Color(hue: hue, saturation: Theme.Calm.Shade.inkSaturationLight, brightness: Theme.Calm.Shade.inkBrightnessLight)
    }

    /// The hue of a seed, 0 to 1.
    public static func hue(for seed: String) -> Double {
        Double(stableHash(seed) % 360) / 360
    }

    /// The colour of a picture, from its bytes, or nil if it will not decode or has no colour in it.
    public nonisolated static func dominantHue(of data: Data) -> Double? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: Theme.Calm.Shade.sampleSide,
              ] as CFDictionary) else { return nil }
        return dominantHue(of: image)
    }

    /// A mean around the colour wheel, each pixel counted by how much colour it has, so a white
    /// background and a black coat say nothing about the hue.
    nonisolated static func dominantHue(of image: CGImage) -> Double? {
        let side = Theme.Calm.Shade.sampleSide
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))

        var x = 0.0, y = 0.0, weight = 0.0
        for pixel in stride(from: 0, to: pixels.count, by: 4) {
            let r = Double(pixels[pixel]) / 255, g = Double(pixels[pixel + 1]) / 255, b = Double(pixels[pixel + 2]) / 255
            let high = max(r, g, b), chroma = high - min(r, g, b)
            guard chroma > 0 else { continue }
            let sector = high == r ? (g - b) / chroma : high == g ? (b - r) / chroma + 2 : (r - g) / chroma + 4
            let angle = sector / 6 * 2 * .pi
            x += cos(angle) * chroma
            y += sin(angle) * chroma
            weight += chroma
        }
        guard weight / Double(side * side) >= Theme.Calm.Shade.leastColour else { return nil }
        let hue = atan2(y, x) / (2 * .pi)
        return hue < 0 ? hue + 1 : hue
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
    /// The hue of the screen being drawn, for the surfaces and the words standing on it.
    @Entry var calmShadeHue: Double?
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
    @Environment(\.calmShadeHue) private var hue
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        switch design {
        case .classic:
            content.navigationGlass(in: shape)
        case .calm:
            content.contentGlass(in: shape,
                                 tint: hue.map {
                                     CalmBackdrop.surfaceShade(hue: $0, in: scheme)
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

/// A short fact in a capsule of glass: a date, floating or in the conversation, "unread messages".
public struct CalmChip<Label: View>: View {
    private let label: Label

    @Environment(\.calmShadeHue) private var hue
    @Environment(\.colorScheme) private var scheme

    public init(@ViewBuilder label: () -> Label) {
        self.label = label()
    }

    public var body: some View {
        label
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .foregroundStyle(CalmBackdrop.ink(hue: hue, in: scheme))
            .padding(.horizontal, Theme.Spacing.normal)
            .padding(.vertical, Theme.Spacing.tight)
            .contentGlass(in: .capsule)
    }
}
