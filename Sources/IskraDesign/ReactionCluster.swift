import SwiftUI

public extension Theme {
    /// The emoji on a bubble's corner, each in a circle of glass.
    enum Reaction {
        public static let circle: CGFloat = 28
        /// How far the first one stands in from the bubble's side.
        public static let edgeInset: CGFloat = 4
        /// How far below the bubble they reach, which the row keeps free for them. The rest of the
        /// circle, 8 points, lies on the bubble: less than its 12 of padding, so never on the words.
        public static let overhang: CGFloat = 20
        /// The most an emoji leans, either way.
        public static let maxTilt: Double = 14
        /// Your own reaction: the same glass as the others, a tone heavier.
        public static let mineTint: Double = 0.22

        /// How far this emoji leans on this message. Looks random, and stays the same every time
        /// the message is drawn, or the emoji would shift on each redraw.
        public static func tilt(for seed: String) -> Double {
            let steps = Int(maxTilt) * 2 + 1
            return Double(Int(stableHash(seed) % UInt64(steps))) - maxTilt
        }

        /// FNV-1a over a string's bytes, because `String.hashValue` changes from one launch to the next.
        private static func stableHash(_ seed: String) -> UInt64 {
            var hash: UInt64 = 0xcbf2_9ce4_8422_2325
            for byte in seed.utf8 {
                hash ^= UInt64(byte)
                hash &*= 0x0000_0100_0000_01b3
            }
            return hash
        }
    }
}

/// Lays a message's emoji along the foot of its bubble: from the bottom right under someone else's,
/// from the bottom left under your own.
///
/// Placed over the bubble, which is why it is a layout of its own: it takes the bubble's size as
/// its bounds and answers with that, so the bubble does not change shape, and it starts from the
/// corner and grows along the bottom edge. When there are more than the bubble is wide, it runs on
/// past the far edge, into the side of the row that is empty, and never off the screen.
public struct ReactionCluster: Layout {
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
        let inset = Theme.Reaction.edgeInset

        var x = isOwn ? min(bounds.minX + inset, bounds.maxX - total)
                      : max(bounds.maxX - inset, bounds.minX + total) - total
        for (subview, size) in zip(subviews, sizes) {
            subview.place(at: CGPoint(x: x, y: bounds.maxY + Theme.Reaction.overhang - size.height),
                          proposal: .unspecified)
            x += size.width + gap
        }
    }
}
