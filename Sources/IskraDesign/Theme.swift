import SwiftUI

/// The handful of numbers the whole app agrees on.
///
/// Everything here is a multiple of 4 and all corners are `.continuous`, which is
/// what gives Apple's own apps their soft, un-fussy geometry. Sizes are *not*
/// hard-coded anywhere else: a bubble that says `.padding(12)` is a bug waiting to
/// drift out of line with the one next to it.
public enum Theme {
    public enum Radius {
        /// Message bubbles, on every corner. Large enough that a one-line message comes
        /// out a capsule and only a wrapped one reads as a rectangle — see `BubbleShape`.
        ///
        /// "Large enough" is a real constraint, not a taste: SwiftUI clamps a corner
        /// radius to half the shorter side, and the capsule is that clamp doing its work.
        /// So this has to stay above half the height of a single-line bubble — one line of
        /// body text plus `Spacing.normal` above and below, about 44pt on iOS, so about 22.
        /// Raise the bubble's vertical padding without raising this and the corners quietly
        /// stop meeting: the shape becomes a rounded rectangle that is *almost* a capsule,
        /// which reads as a mistake rather than as a decision.
        public static let bubble: CGFloat = 24

        /// The picture inside a picture bubble. Smaller than the bubble by the padding
        /// between the two, so the two curves are concentric: a corner drawn at the bubble's
        /// own radius inside the bubble's own inset would run *outside* the shape it sits in,
        /// and the eye reads that as a picture pushing through its frame.
        public static let picture: CGFloat = 20
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

        /// How far the emoji under a message climb back onto it.
        ///
        /// Negative space, spent deliberately. Pills sitting in a clean row *below* the
        /// bubble read as a separate thing that happens to be nearby; tucked over its
        /// bottom edge they read as belonging to it — the same trick every messenger uses,
        /// and the reason a reaction never has to be joined to its message by a line.
        public static let reactionOverlap: CGFloat = 8

        /// How far the emoji step in from the edge of the message they belong to — from the
        /// left under someone else's, from the right under your own.
        ///
        /// Flush with the bubble's edge, a pill lines up with the widest point of a shape
        /// whose corner is already curving away beneath it, and it reads as having slipped
        /// off rather than as being tucked under. Stepped in, it sits over the bubble's
        /// solid body. The step is *inwards*, which is why it swaps sides with the message:
        /// the edge it comes away from is the one the conversation is anchored to.
        public static let reactionInset: CGFloat = 12
    }

    /// The few durations the app agrees on. Not `Duration` — that is Swift's own type, and
    /// shadowing it inside `Theme` would make every `Duration.seconds(…)` in the package
    /// mean something subtly different.
    public enum Timing {
        // There was a `longPress` here, and it is gone with the menu it opened: a message
        // wears the system's own `.contextMenu` now, and how long the system waits before
        // lifting the bubble is the system's business — see `MessageRow.actionableContent`.
        // The impatient path is the double tap, which does not wait at all.

        /// Reactions arriving and leaving.
        public static let reaction: TimeInterval = 0.25

        /// A message being taken back: the bubble collapsing into the "deleted" line, or —
        /// for one that never left the device — leaving the timeline altogether.
        ///
        /// Slower than a reaction on purpose. A reaction is a small thing appearing beside
        /// what you were already reading; a message vanishing changes what the conversation
        /// says, and it should be possible to see it happen rather than to notice afterwards
        /// that something is gone.
        public static let deletion: TimeInterval = 0.3

        /// A video note growing as it starts, and settling back when it ends.
        ///
        /// A spring rather than a duration, because the circle should arrive with a little
        /// weight behind it instead of gliding to a halt — it is the one thing on screen that
        /// is *happening*, and it is allowed to say so. Barely any bounce: this runs on a
        /// message in a list, and a circle that wobbles under the words around it is a toy.
        ///
        /// Note that a spring this gentle is not what made the growth stutter, and softening
        /// it further would not have fixed anything — the jerking was `AVPlayerLayer` running
        /// an animation of its own underneath this one. See `PlayerHostView.noAnimations`.
        public static let videoNote: Animation = .spring(duration: 0.4, bounce: 0.15)

        /// How long a message stays lit after the conversation has jumped to it.
        ///
        /// Long enough to find with the eye — the jump lands the message in the middle of a
        /// screenful of other messages, and without the light the user has to work out which one
        /// they were sent to. Short enough that it fades on its own: it is an answer to a
        /// question that has been asked, not a state the room is now in.
        public static let highlight: TimeInterval = 1.6

        /// How long a finger has to stay down on the record button before it is recording rather
        /// than tapping it to change what it records.
        ///
        /// The twin of `Size.gestureReach`, and it lives here for the same reason: it is a
        /// threshold the user feels, and a number the app has an opinion about. Long enough that
        /// a decisive tap never records; short enough that a hold does not feel ignored.
        public static let holdBegins: Duration = .milliseconds(250)
    }

    /// The lines the app draws *around* things rather than under them. There are very few:
    /// a border is what a surface reaches for when it has no fill to describe itself with.
    public enum Border {
        public static let hairline: CGFloat = 1

        /// The dashes of the outline a deleted message leaves behind — see `deletedBubble`.
        /// Even dash and gap, so the line reads as a placeholder rather than as a decoration.
        public static let dash: [CGFloat] = [4, 4]
    }

    /// The picture behind a picture: a photo's own bubble is that photo, blurred out of
    /// legibility and darkened until nothing on it competes with the sharp copy in front.
    ///
    /// Every other bubble in the app has a fill — the accent on your own, grey on somebody
    /// else's — and a photo used to have none at all: it *was* the bubble, and a caption under
    /// it sat on the bare page. So a picture message had no body, and the words that came with
    /// the picture belonged to nothing. The blurred photo is that missing body, and it is made
    /// of the one thing that is certainly the right colour for this message: the message.
    ///
    /// This is **not** glass, and no `.navigationGlass()` may go here — a bubble is content
    /// and content does not get Liquid Glass (see `IskraDesign/Glass.swift`). It is a picture
    /// with a blur applied to it, which is a different thing entirely: an opaque, static
    /// backdrop that samples nothing behind it.
    public enum Backdrop {
        /// Far enough that no face, no word and no logo survives it. A gentler blur would
        /// leave a picture legible behind the picture, which is two photographs at once.
        public static let blur: CGFloat = 24

        /// And how far it is taken down, so that white caption text is readable over a photo
        /// of a snowfield as surely as over one of a night sky.
        public static let dim: Double = 0.45

        /// The backdrop is drawn a third larger than the space it fills, and then clipped.
        ///
        /// A blur samples the transparency *outside* the view as well as the colour inside it,
        /// so a blurred image fades out at its own edges — laid straight into the bubble, the
        /// bubble's rim would go translucent and the conversation would show through the
        /// frame. Overdrawing pushes those soft edges out past the clip.
        public static let overdraw: CGFloat = 1.3
    }

    public enum Size {
        public static let avatar: CGFloat = 40
        public static let avatarSmall: CGFloat = 28
        /// A picture that *is* a button in the title bar: the chat's, at the end of a room's
        /// bar, and the user's own at the end of the room list's.
        ///
        /// Much larger than `avatarSmall`, which is sized to stand beside a line of text and
        /// match its height. This one stands alone in a 44pt glass circle, and at 28pt it was
        /// a small face marooned in the middle of it. It is sized instead to very nearly fill
        /// the button: what is left is the ring of glass that says it is one.
        ///
        /// The circle is `.buttonBorderShape(.circle)` at the site — a toolbar button left to
        /// its own devices takes a capsule, and a capsule around a round picture is what put
        /// the phantom margins down either side of it.
        public static let avatarToolbar: CGFloat = 36
        /// The user's own picture, at the top of the settings screen.
        public static let avatarLarge: CGFloat = 64
        /// Video notes are circles; this is their diameter in the timeline.
        public static let videoNote: CGFloat = 200

        /// How much bigger a video note gets while it plays, where it is not simply filling
        /// the screen — a Mac or an iPad. Twice: enough to be watched from across a desk,
        /// small enough to still be a message in a conversation.
        public static let videoNoteGrowth: CGFloat = 2

        /// The room the clock beside a bubble takes, and the widest a playing video note may
        /// therefore grow: everything else the row has, minus this.
        ///
        /// A number rather than a measurement, because it is used to *propose* a size and the
        /// clock's real width is only known once that proposal has been laid out — asking for
        /// it here would be asking the layout a question that depends on the answer. It is a
        /// generous fit for "23:59" with its padding, and being a little generous is the safe
        /// direction: too small and the circle would shoulder the clock off the screen.
        public static let clockColumn: CGFloat = 56
        /// Nothing tappable is ever smaller than this. Apple's floor, and ours.
        public static let minimumTapTarget: CGFloat = 44

        /// A colour to choose the app's accent from, on the appearance screen. A full tap
        /// target: a swatch is a button, and a colour you have to aim at is a colour you
        /// pick by accident.
        public static let swatch: CGFloat = 44

        /// The bar down the side of a quoted message. Narrow, and the whole of what makes a
        /// quote read as one.
        public static let quoteBar: CGFloat = 4

        /// The play button on a voice message, and the tallest a bar of its waveform may be.
        ///
        /// The button is smaller than `minimumTapTarget` and it is allowed to be: it sits
        /// *inside* a bubble whose every part is already a tap target — the bubble takes the
        /// long press, the double tap, the reaction — and growing this to 44pt would push the
        /// waveform out of the bubble rather than making anything easier to hit.
        public static let voiceButton: CGFloat = 28
        public static let waveform: CGFloat = 24

        /// The red dot that says the microphone is live.
        public static let recordingDot: CGFloat = 10

        /// How wide a quote is allowed to get, above the composer and inside a bubble.
        ///
        /// A limit rather than a size — a short answer to a short message should not be
        /// stretched to this. It exists because a quote is a *reference* to a message and not
        /// the message: left unbounded inside a bubble, a quoted paragraph would set the width
        /// of the answer to it, and the reply would be shaped by the thing it is replying to.
        public static let quote: CGFloat = 260

        /// How wide a photo or a video still is drawn in the timeline.
        public static let picture: CGFloat = 280

        /// How much of the conversation's width a message may take before the far side of
        /// the screen starts pushing back.
        ///
        /// A message has to be visibly *from* somebody — a bubble spanning the whole width is
        /// a paragraph on a page, and the empty column beside it is what says which side of
        /// the conversation it belongs to. But that column used to be 60 points flat, which is
        /// a sixth of a phone and a rounding error on a Mac: the same message was cramped on
        /// the device it was written on and adrift in the window it was read in. A fraction is
        /// the same *proportion* everywhere, and a tenth is enough of a margin to read as one
        /// while leaving a long message the room to be long.
        public static let bubbleWidthFraction: CGFloat = 0.9

        /// And how tall a map is. Shorter than it is wide, because a place is a point and the
        /// context that matters around it is the streets either side, not the sky above.
        public static let map: CGFloat = 160

        /// The pin in the middle of the map picker. Big enough to aim with.
        public static let crosshair: CGFloat = 32

        /// And how tall, at most: half of what is on screen.
        ///
        /// A limit, not a size. A portrait photo at `picture` wide would otherwise run
        /// two or three screens deep and the conversation around it would be gone — you
        /// would scroll through a picture rather than past it. Half a screen is enough to
        /// see what was sent and still leaves the messages on either side of it in view.
        /// It is a fraction rather than a number because a Mac window and an iPhone are
        /// not the same height, and half of each is the point.
        public static let pictureHeightFraction: CGFloat = 0.5

        /// The smallest an opened video is allowed to be. It matters on the Mac, where the
        /// viewer is a sheet rather than the whole screen and would otherwise shrink to the
        /// size of the spinner it starts out showing.
        public static let viewer: CGFloat = 480

        /// The sheet that shows the recovery key, once and never again. Fixed rather than
        /// flexible because of the Mac, where a sheet is as wide as it is allowed to be and
        /// a key allowed to stretch across it stops being a thing you can read back one
        /// character at a time.
        public static let keySheet: CGFloat = 360

        /// The red badge beside a message that failed to send. Bigger than the delivery
        /// ticks on purpose: those report progress and may be ignored, this one is the
        /// only sign that a message the user believes they sent is still sitting there.
        public static let failureBadge: CGFloat = 20

        /// The popover that says why it failed. Wide enough for a sentence to wrap two or
        /// three times, and fixed rather than flexible — see `SendFailureBadge`.
        public static let failurePopover: CGFloat = 280

        /// The height of the composer's text field, and therefore the diameter of the
        /// round buttons on either side of it: the three read as one row only if they
        /// are the same size, so this is one number rather than three.
        public static let composerControl: CGFloat = 44

        /// The search field floating at the bottom of the room list. The same height as
        /// the composer, and for the same reason — it sits where the thumb already is.
        public static let searchField: CGFloat = 44

        /// How far a thumb has to travel, mid-hold, for the movement to mean something.
        ///
        /// The one escape from a recording that does not need the finger lifted — up, to carry
        /// on hands-free — and it is a real threshold rather than a nicety: a finger held still
        /// on a button is never actually still, and a few points of drift must not turn somebody
        /// letting go into somebody locking.
        public static let gestureReach: CGFloat = 60

        /// The camera, while a round video message is being recorded.
        ///
        /// Very nearly the width of a phone, and that is the point: this is the one thing on the
        /// screen, the room behind it is blurred out, and a circle sitting in the middle of all
        /// that with a hand's breadth of empty blur on either side reads as a preview of a
        /// preview. It is also what the user is *framing their face in* — a bubble in a
        /// conversation is looked at, but this is looked *into*, and there is no reason to make
        /// them do it through a smaller window than the screen can give.
        ///
        /// 320 rather than more: the narrowest screen this app runs on is 375pt, and the overlay
        /// spends `Spacing.roomy` on each side of it.
        public static let videoNoteCamera: CGFloat = 320

        /// The button that sends what is being recorded. Larger than a composer control on
        /// purpose: it is the only thing on the screen the thumb is looking for.
        public static let recordingSend: CGFloat = 72

        /// How close to the top of a conversation counts as asking for more of it.
        ///
        /// Not zero, deliberately: fetching only once the user has hit the very top means
        /// they watch a spinner. A screenful of slack ahead of them means the next page is
        /// usually already there by the time they get to where it goes.
        public static let paginationReach: CGFloat = 400

        /// How close to the newest message counts as standing on it — and therefore as having
        /// asked to be brought along when the next one arrives.
        ///
        /// Small, and much smaller than `paginationReach`, because it answers a different
        /// question. That one is generous on purpose: fetching early is free, and the cost of
        /// guessing wrong is a page nobody reads. This one decides whether to *move the screen
        /// under somebody's eyes*, and the cost of guessing wrong is losing their place in a
        /// conversation they were reading. A screenful of slack would do exactly that.
        public static let newestReach: CGFloat = 80

        /// How much of the title bar the chat's name and avatar may take.
        ///
        /// A limit rather than a size: a title bar has buttons in both corners, and a room
        /// called "Design — everything, all of it, forever" will happily walk straight over
        /// them given the chance. Capped, the name truncates instead.
        public static let roomHeader: CGFloat = 260
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

    /// The fill behind a reaction *you* left.
    ///
    /// The same grey as every other pill, a tone heavier — not a different colour. The pills
    /// used to say "mine" in the accent, tinted and ringed, and a row of those under a busy
    /// message read as a row of buttons shouting over the words above them. A reaction is a
    /// footnote. So the distinction stays, and it stays in weight: the same material, pressed
    /// a little harder, which is exactly how an outgoing bubble is told from an incoming one
    /// on the mono theme.
    static var ownReaction: Color {
        Color.primary.opacity(0.16)
    }
}
