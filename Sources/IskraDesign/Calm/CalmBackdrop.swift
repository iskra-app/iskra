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
                Color(hue: Self.hue(for: seed),
                      saturation: Theme.Calm.Shade.saturation,
                      brightness: scheme == .dark ? Theme.Calm.Shade.brightnessDark : Theme.Calm.Shade.brightnessLight)
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

    /// The hue of a seed, 0 to 1. FNV-1a over its bytes, because `String.hashValue` changes from one
    /// launch to the next and a room's colour must not.
    static func hue(for seed: String) -> Double {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in seed.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01b3
        }
        return Double(hash % 360) / 360
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
