import SwiftUI

/// The handful of numbers the whole app agrees on.
///
/// Everything here is a multiple of 4 and all corners are `.continuous`, which is
/// what gives Apple's own apps their soft, un-fussy geometry. Sizes are *not*
/// hard-coded anywhere else: a bubble that says `.padding(12)` is a bug waiting to
/// drift out of line with the one next to it.
public enum Theme {
    public enum Radius {
        /// Message bubbles. Deliberately large — this is the app's signature shape.
        public static let bubble: CGFloat = 20
        /// The corner where a bubble meets its owner's edge, tucked in so a run of
        /// messages reads as one column rather than a stack of identical pills.
        public static let bubbleAnchor: CGFloat = 6
        public static let card: CGFloat = 16
        public static let control: CGFloat = 12
        /// Avatars and video notes.
        public static let circle: CGFloat = .infinity
    }

    public enum Spacing {
        public static let tight: CGFloat = 4
        public static let close: CGFloat = 8
        public static let normal: CGFloat = 12
        public static let roomy: CGFloat = 16
        public static let generous: CGFloat = 24
        /// Between two messages from different people.
        public static let betweenSenders: CGFloat = 12
        /// Between two messages from the same person.
        public static let withinRun: CGFloat = 2
    }

    public enum Size {
        public static let avatar: CGFloat = 40
        public static let avatarSmall: CGFloat = 28
        /// Video notes are circles; this is their diameter in the timeline.
        public static let videoNote: CGFloat = 200
        /// Nothing tappable is ever smaller than this. Apple's floor, and ours.
        public static let minimumTapTarget: CGFloat = 44
    }
}

public extension ShapeStyle where Self == Color {
    /// The fill behind a message someone else sent.
    ///
    /// A neutral, hierarchical fill rather than a chosen grey, so it follows the
    /// system into dark mode and into increased-contrast mode without our help.
    static var incomingBubble: Color {
        Color.primary.opacity(0.08)
    }
}
