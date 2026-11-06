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

    /// The secondary words on the light ground, in the same hue: a form's footers, a row's value.
    public static func inkSoftLight(hue: Double?) -> Color {
        guard let hue else { return Theme.Calm.inkSoft }
        return Color(hue: hue,
                     saturation: Theme.Calm.Shade.inkSoftSaturationLight,
                     brightness: Theme.Calm.Shade.inkSoftBrightnessLight)
    }

    /// The hue of a seed, 0 to 1.
    public static func hue(for seed: String) -> Double {
        Double(stableHash(seed) % 360) / 360
    }

    /// The most expressive colour in a picture, as a hue, from its bytes. Nil if it will not decode
    /// or has no real colour in it. Only the hue is kept: how bright and how saturated the screen
    /// comes out is the look's decision (`Theme.Calm.Shade`).
    public nonisolated static func dominantHue(of data: Data) -> Double? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: Theme.Calm.Shade.sampleSide,
              ] as CFDictionary) else { return nil }
        return dominantHue(of: image)
    }

    /// A vote around the colour wheel, in which a pixel's vote is the cube of how much colour it has. A small red thing on a big grey picture wins, since grey has almost no vote, and it beats
    /// a large washed-out area too. The winner is a peak and not an average: red and blue in one
    /// picture give red or blue, never the purple that is in neither.
    nonisolated static func dominantHue(of image: CGImage) -> Double? {
        let side = Theme.Calm.Shade.sampleSide
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))

        let count = Theme.Calm.Shade.hueBuckets
        var votes = [(x: Double, y: Double, weight: Double)](repeating: (0, 0, 0), count: count)
        for pixel in stride(from: 0, to: pixels.count, by: 4) {
            let r = Double(pixels[pixel]) / 255, g = Double(pixels[pixel + 1]) / 255, b = Double(pixels[pixel + 2]) / 255
            let high = max(r, g, b), chroma = high - min(r, g, b)
            // Below this it is grey with noise in it, and a hue read off noise means nothing.
            guard chroma >= Theme.Calm.Shade.leastColour else { continue }
            let sector = high == r ? (g - b) / chroma : high == g ? (b - r) / chroma + 2 : (r - g) / chroma + 4
            let hue = (sector / 6 + 1).truncatingRemainder(dividingBy: 1)
            let weight = chroma * chroma * chroma
            let bucket = min(Int(hue * Double(count)), count - 1)
            votes[bucket].x += cos(hue * 2 * .pi) * weight
            votes[bucket].y += sin(hue * 2 * .pi) * weight
            votes[bucket].weight += weight
        }

        // A bucket with its two neighbours, so that a colour on the line between two is not split.
        func around(_ i: Int) -> [(x: Double, y: Double, weight: Double)] {
            [votes[(i + count - 1) % count], votes[i], votes[(i + 1) % count]]
        }
        let totals = (0..<count).map { around($0).map(\.weight).reduce(0, +) }
        guard let best = totals.indices.max(by: { totals[$0] < totals[$1] }), totals[best] > 0 else { return nil }
        let peak = around(best)
        let hue = atan2(peak.map(\.y).reduce(0, +), peak.map(\.x).reduce(0, +)) / (2 * .pi)
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
