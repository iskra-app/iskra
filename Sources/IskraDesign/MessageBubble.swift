import SwiftUI

/// The shape of a message bubble.
///
/// Three of the corners are generously round; the fourth — the one on the sender's
/// own side, at the bottom of a run — is tucked in. That single asymmetry is what
/// makes a column of bubbles read as a conversation anchored to one edge rather than
/// as a stack of identical pills, and it is the whole of the app's visual signature.
public struct BubbleShape: Shape {
    let isOwn: Bool
    /// True when another message from the same person follows immediately below, in
    /// which case the tail stays round and the run reads as one block.
    let isFollowedBySameSender: Bool

    public init(isOwn: Bool, isFollowedBySameSender: Bool = false) {
        self.isOwn = isOwn
        self.isFollowedBySameSender = isFollowedBySameSender
    }

    public func path(in rect: CGRect) -> Path {
        let round = Theme.Radius.bubble
        let tucked = isFollowedBySameSender ? round : Theme.Radius.bubbleAnchor

        let corners = RectangleCornerRadii(
            topLeading: round,
            bottomLeading: isOwn ? round : tucked,
            bottomTrailing: isOwn ? tucked : round,
            topTrailing: round
        )

        return UnevenRoundedRectangle(cornerRadii: corners, style: .continuous).path(in: rect)
    }
}

public extension View {
    /// Dresses a message in its bubble.
    ///
    /// Note what this does *not* do: apply glass. Bubbles are content, and the HIG
    /// reserves Liquid Glass for the navigation layer. A glass bubble would also be
    /// unreadable over a photo, which is exactly where bubbles end up.
    func messageBubble(isOwn: Bool, isFollowedBySameSender: Bool = false) -> some View {
        let shape = BubbleShape(isOwn: isOwn, isFollowedBySameSender: isFollowedBySameSender)

        return padding(.horizontal, Theme.Spacing.normal)
            .padding(.vertical, Theme.Spacing.close)
            .foregroundStyle(isOwn ? .white : .primary)
            .background(isOwn ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.incomingBubble),
                        in: shape)
            // Lets a long-press menu and drag preview take the bubble's shape rather
            // than a rectangle around it.
            .contentShape(shape)
    }
}
