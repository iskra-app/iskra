import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The handful of numbers the whole app agrees on.
///
/// Spacings and sizes are multiples of 4 and all corners are `.continuous`, which is what gives
/// Apple's own apps their soft, un-fussy geometry. Sizes are *not* hard-coded anywhere else: a
/// bubble that pads itself by a bare twelve points is a bug waiting to drift out of line with the
/// one next to it.
///
/// Two things in here are **not** multiples of 4, and the rule used to claim otherwise about them —
/// which is a small lie of the kind that eventually gets one of them "corrected". `Spacing.withinRun`
/// is 2, because the gap inside a run of messages from one person is meant to be *tighter* than the
/// grid, and 4 reads as two separate remarks. `Size.recordingDot` is 10, because it is a dot and a
/// dot is sized by eye against the text beside it, not by a grid it is not standing on.
///
/// The grid is for the things that line up with each other. These two line up with nothing.
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

        /// The corner of an app icon drawn at some size — see `Size.appIconTile`.
        ///
        /// A proportion rather than a constant, because that is what the home screen's corner
        /// is: iOS rounds an icon to a fixed *fraction* of its side, so a tile drawn with any
        /// fixed radius reads as the right picture in the wrong shape. The fraction is the one
        /// the system uses.
        public static func appIcon(side: CGFloat) -> CGFloat { side * 0.2237 }
        public static let card: CGFloat = 16
        public static let control: CGFloat = 12

        /// The menu a long press opens, and the panel of emoji beside it — see `MessageMenu`.
        ///
        /// Rounder than a card and rounder than this app's own instinct, because it is the one
        /// surface here that has to pass for a system one. Apple's floating panels on 26 are
        /// drawn at something close to this, the capsule of emoji above the menu is drawn at
        /// half its own height, and a 16-point corner between the two reads as a dialog box
        /// that wandered in from an older release.
        public static let menu: CGFloat = 28
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

        /// How much air a conversation gets above and below it in the Mac's own sidebar.
        ///
        /// Less than the list would choose, and on purpose. The system's own row insets are
        /// measured for what a sidebar usually holds — one line of text with a small symbol
        /// beside it — while a row here is a 56-point face, a name, and two reserved lines of the
        /// last message. Spent on a row four times the height it was sized for, that breathing
        /// room stops reading as breathing room and starts reading as a gap: the same window
        /// holds noticeably fewer conversations, and a chat list is a thing you scan.
        ///
        /// Zero, and that is not the same as no padding. What separates one conversation from the
        /// next in a sidebar is the gap the list leaves *between* the selection shapes, which this
        /// does not touch; what this measures is the air inside the shape, around a row that
        /// already carries its own — a 56-point face is taller than the name and the message
        /// stacked beside it, so the row arrives with room to spare before anything is added.
        public static let sidebarRow: CGFloat = 0
    }

    /// The few durations the app agrees on. Not `Duration` — that is Swift's own type, and
    /// shadowing it inside `Theme` would make every `Duration.seconds(…)` in the package
    /// mean something subtly different.
    public enum Timing {
        /// How long a finger stays on a message before the menu lifts it.
        ///
        /// This constant has now been deleted once and written twice, which is worth saying out
        /// loud: it went away when the hand-drawn menu did, and it is back because the menu is
        /// ours again — see `MessageMenu`. The number is the argument. The system's own
        /// `.contextMenu` waits about half a second and will not be talked down, and on a message
        /// you have already decided to answer that wait reads as the app deliberating.
        ///
        /// It went three tenths, a sixth, a tenth — each step down asked for by the same
        /// complaint, that the press still felt like being made to wait — and every one of those
        /// steps was chasing a delay that was never in this number. Two other things were holding
        /// the touch: the scroll view kept it back about 150 ms before the clock here even started
        /// (`ScrollTouches`), and the double tap kept it back about three quarters of a second
        /// after that, because a tap recogniser given first refusal does not fail while a finger
        /// rests — it fails on its own timeout (`MessageActions.press`). With both gone, a tenth
        /// of a second turned out to be a tenth of a second, and a tenth of a second is *too
        /// short*: it lifts a message out from under a finger that was only resting there before a
        /// scroll, and it makes the hold and the tap on a photograph very nearly the same gesture.
        ///
        /// A quarter of a second is the number that is actually about the gesture rather than
        /// about a bug behind it. Half the system's wait, so it still reads as quick; long enough
        /// that holding is a decision. And now that the wait is real, it is *shown* — the bubble
        /// sinks through exactly this long and arrives at the lift, so the quarter second is spent
        /// watching something happen rather than waiting for it. See `Scale.pressedMessage`.
        public static let menuLift: TimeInterval = 0.25

        /// The bubble coming back up when a press is abandoned — the finger lifted early, or the
        /// press turned into a scroll.
        ///
        /// A spring with some bounce in it, which is the one place in this app a bounce is right:
        /// the message was pushed and let go, and a thing let go comes back past where it started.
        /// The sink itself is not a spring — it is a plain ease-out lasting exactly `menuLift`,
        /// because it is a progress bar wearing a better costume and a progress bar must not
        /// overshoot the thing it is measuring.
        public static let menuReleases: Animation = .spring(response: 0.3, dampingFraction: 0.55)

        /// The menu arriving: the bubble rising off the page, the bar and the list opening
        /// around it. A spring, because the lift is the one moment in a conversation where the
        /// app is *picking something up*, and things that are picked up have weight.
        public static let menuOpens: Animation = .spring(response: 0.34, dampingFraction: 0.78)

        /// Reactions arriving and leaving.
        public static let reaction: TimeInterval = 0.25

        /// The furniture rearranging itself: the composer growing a strip, the send button taking
        /// the microphone's place, the search field opening, the jump-to-newest button appearing.
        ///
        /// Written out as a bare `0.25` in nine different places, which is not nine decisions — it
        /// is one decision made once and copied, and the ninth copy is where somebody types `0.3`
        /// by accident and nobody ever notices that one control moves differently from the rest.
        public static let chrome: TimeInterval = 0.2

        /// A message being taken back: the bubble collapsing into the "deleted" line, or —
        /// for one that never left the device — leaving the timeline altogether.
        ///
        /// Slower than a reaction on purpose. A reaction is a small thing appearing beside
        /// what you were already reading; a message vanishing changes what the conversation
        /// says, and it should be possible to see it happen rather than to notice afterwards
        /// that something is gone.
        public static let deletion: TimeInterval = 0.3

        /// A message arriving in the conversation — one you have just sent, or one that has
        /// just been said to you.
        ///
        /// A spring, and the twin of `deletion` at the other end of a message's life. A message
        /// leaving is slow on purpose, because the conversation has lost something and the reader
        /// should be able to see it go. A message arriving is the opposite errand: it has weight
        /// and it should land, not glide in. The bounce is small — a bubble that wobbles under
        /// the words above it is a toy — and it is there so the arrival reads as a thing put down
        /// rather than as a fade somebody might miss.
        ///
        /// It is carried by the transition on the row rather than by the animation scope around
        /// the list (see `RoomView`), because that scope belongs to the removal and the two are
        /// not the same gesture.
        public static let arrival: Animation = .spring(duration: 0.32, bounce: 0.18)

        /// How long a room that has just opened stays perfectly still before it is allowed to
        /// animate anything.
        ///
        /// A conversation does not arrive in one piece — the first page comes in batches, the
        /// events decrypt after they are drawn, and their pictures land after that. Every one of
        /// those is a change to the list, and a list that animates its changes spends the first
        /// half-second of every room sliding. So it does not: it is drawn where it is, and only
        /// then does movement start to mean something. See `RoomView.hasSettled`.
        public static let timelineSettles: Duration = .milliseconds(400)

        /// The longest a room will stay blank waiting to be shown whole.
        ///
        /// A conversation is fetched in several round trips, and it is not shown until they are
        /// done — see `RoomView.isRevealed`. That is a promise about somebody else's server, so
        /// there is a floor under it: past this, the room shows what it has, because a partly
        /// fetched conversation beats an empty screen that goes on being empty.
        public static let roomWaitsToBeSeen: Duration = .milliseconds(2500)

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
        ///
        /// It was briefly shortened to 180 ms, to cure a hold that seemed to do nothing for about
        /// a second. It was not the culprit: the second was the microphone being opened behind an
        /// unchanged screen, and it is cured where it was caused — see `VoiceRecorder.State.starting`.
        /// So this is a quarter of a second again, which is the number that keeps the widest margin
        /// between a hold and the tap that flips the button between voice and video.
        public static let holdBegins: Duration = .milliseconds(250)

        /// How long one slide of the welcome carousel stands still before the next one comes.
        ///
        /// Long enough to read two lines without hurrying — the slides are the app's only pitch,
        /// and a carousel that moves while somebody is still reading it is a carousel they fight.
        /// Short enough that a person who is not reading gets through all six on the way to the
        /// button. See `WelcomeView`, which stops the timer at the last slide rather than looping:
        /// once everything has been said, the screen waits.
        public static let welcomeSlide: Duration = .seconds(5)

        /// How long the hello stands on screen before the first run moves on.
        ///
        /// Three seconds: long enough to be read and to register as the app saying something
        /// rather than as a flash between two screens, short enough that nobody waits for it. It
        /// is a greeting and not a step, so there is nothing on it to press — see `FirstRunView`.
        public static let greeting: Duration = .seconds(3)
    }

    /// Things drawn smaller than they are, as feedback. There is exactly one so far, and it has a
    /// name here for the same reason every spacing does: the next view to squeeze something under a
    /// finger should squeeze it by the same amount.
    public enum Scale {
        /// How far a message gives under a finger on its way into the menu.
        ///
        /// Deeper than the 0.97 a button gives (`View.pressed(_:)`), and deliberately: a button's
        /// squeeze says "heard you" about a press that is already over, while this one is a
        /// *countdown* — it starts when the finger lands and finishes exactly as the menu lifts, so
        /// the wait has something to look at. At 0.97 that journey is invisible; at 0.94 it reads
        /// as the message being picked up, and it is still far from the cartoon squash that a
        /// deeper number would give a wall of text.
        public static let pressedMessage: CGFloat = 0.94
    }

    /// The lines the app draws *around* things rather than under them. There are very few:
    /// a border is what a surface reaches for when it has no fill to describe itself with.
    public enum Border {
        public static let hairline: CGFloat = 1

        /// A ring that has to be seen from across a grid rather than merely be present — the
        /// chosen app icon's. A hairline around a 60-point picture is a line the eye has to be
        /// looking for.
        public static let thick: CGFloat = 2

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
        /// A colour laid under text as a *panel* rather than as a fill — the red behind the
        /// sign-in error. Faint enough that the words on it stay the loudest thing there, strong
        /// enough that the panel is a shape and not a smudge.
        public static let wash: Double = 0.12

        /// Far enough that no face, no word and no logo survives it. A gentler blur would
        /// leave a picture legible behind the picture, which is two photographs at once.
        public static let blur: CGFloat = 24

        /// The dark capsule that carries white text over a photograph or a video — the clock in
        /// the corner of a picture, the duration on a video note, "couldn't load this".
        ///
        /// One number, and it was three: 0.4, 0.45 and 0.5, on three capsules that are the same
        /// capsule doing the same job in the same place. Nobody chose three; somebody wrote one,
        /// somebody else needed another and typed a number that looked about right, and a third
        /// did it again. The photograph underneath is unknown and may be white, so the plate has
        /// to be dark enough to carry white text over a snowfield — and it has to be *the same*
        /// plate every time, or the app looks as though it was assembled rather than designed.
        public static let plate: Double = 0.45

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

    public enum Tint {
        /// How much of the accent is washed across the whole app when "tint the interface" is on:
        /// a single translucent sheet of the accent laid over everything the app has drawn, so the
        /// page, the message bubbles and the words all take a breath of the colour at once.
        ///
        /// Deliberately faint. This sits *over* the text as well as the background — it has to, or
        /// it could not reach the system's own grouped-list backgrounds, which are drawn opaque and
        /// answer to nothing else — so anything heavier would start to grey out the very words it is
        /// tinting. Eight percent is the most the colour can say here before legibility is the thing
        /// paying for it.
        public static let interface: Double = 0.08

        /// The same wash, on the mono theme, where it is not a colour at all.
        ///
        /// A colour laid over the app tints it; black or white laid over the app only takes the
        /// light out of it or puts it in, and it does that to the text as much as to the page. The
        /// eight percent a hue can afford is visibly too much here — it is the difference between
        /// a monochrome app and a dimmed one — so the colourless theme is washed at half of it.
        /// See `AccentTheme.washOpacity`.
        public static let mono: Double = 0.04
    }

    public enum Size {
        public static let avatar: CGFloat = 40

        /// The face beside a conversation in the chat list.
        ///
        /// Bigger than `avatar`, and it is a size of its own rather than a bump to that one
        /// because `avatar` is also worn by the members of a room — a list of *names*, where the
        /// picture is an ornament beside the word that matters. In the chat list the picture is
        /// how a conversation is found: the eye goes down the column of faces, not down the column
        /// of names, and at 40pt it was doing that work at the size of a footnote.
        public static let roomAvatar: CGFloat = 56
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

        /// The face at the top of a profile — yours in settings, the room's on the info screen.
        ///
        /// Much larger than `avatarLarge`, and that is the point of the header: the picture is not
        /// an ornament beside a name, it is the first thing on the screen and the name sits under
        /// it. At 64 the same layout reads as a list row that has been centred by mistake; at this
        /// size it reads as a portrait, which is what people are looking for when they open
        /// somebody's card.
        ///
        /// It is also the distance the screen scrolls before the picture is gone, which is what
        /// switches the scroll edge effect back on — see `profileScreen()`.
        public static let avatarProfile: CGFloat = 96
        /// How tall a navigation bar is on iPhone, and the only number in here that describes
        /// something the app did not draw.
        ///
        /// It is here because a profile screen is pulled up by exactly this much, so that the top
        /// of the portrait lands level with the top of the buttons either side of it — see
        /// `profileScreen()`. UIKit exposes no constant for it and SwiftUI exposes nothing at all;
        /// 44 is what every iPhone has used since the notch, portrait and landscape alike, and a
        /// screen that guessed it locally would be a magic number in three different files.
        public static let navigationBar: CGFloat = 44

        /// Video notes are circles; this is their diameter in the timeline.
        public static let videoNote: CGFloat = 200

        /// The longest edge of a sticker. Smaller than a photo (`Radius.picture`'s bubble is
        /// 280 across) on purpose: a sticker is a remark, not something to look at, and one
        /// blown up to the width of the conversation stops being a gesture and becomes a
        /// poster.
        public static let sticker: CGFloat = 160

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

        /// A wallpaper to choose from, on the same screen. Not a swatch: a background is judged
        /// as a *screen*, so the tile is the shape of one — tall, in roughly the proportion of a
        /// phone — and big enough that a gradient reads as a gradient rather than as a smudge.
        public static let wallpaperTile = CGSize(width: 72, height: 128)

        /// An app icon to choose from, on the icon screen. Square, and larger than a swatch
        /// because what is being judged is a picture rather than a colour — at swatch size the
        /// spark in the middle of it is a speck.
        public static let appIconTile: CGFloat = 60

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

        /// One bar of that waveform: how wide it is drawn, and the shortest it may be so that a
        /// silent stretch is still a mark on the line rather than a gap in it.
        public static let waveformBar: CGFloat = 2
        public static let waveformBarMinimum: CGFloat = 3

        /// The red dot that says the microphone is live.
        public static let recordingDot: CGFloat = 10

        /// The little pill above the record button, and the thing the swipe up is swiping
        /// *towards*.
        ///
        /// It is not decoration and it is not a button — nobody presses it, and it is gone the
        /// moment it has been reached. It exists because the gesture had no target: the reach is
        /// `gestureReach` and there was nothing at the end of it, so a user who lifted a thumb
        /// halfway there could not tell whether the app had refused the lock or never offered it.
        /// Narrower than the button it sits over, and tall enough to be visibly *travelled*.
        public static let recordLock = CGSize(width: 40, height: 64)

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

        /// The single centred column that getting into the app is laid out in — the sign-in screen,
        /// and the recovery screen that follows it. Named once and shared, because the two are one
        /// continuous act to the person performing it, and a column that changed width halfway
        /// through would be the seam showing.
        ///
        /// It was named once and then *not* shared: the sign-in screen went on saying `420` in its
        /// own hand, which is exactly the drift the paragraph above was written to prevent, and it
        /// meant this constant could have been changed with no effect on the screen it is named for.
        public static let signInColumn: CGFloat = 420

        /// The symbol over the sign-in screen — the first thing anyone sees of this app, and the
        /// only mark it has.
        ///
        /// Bigger than any `Font.TextStyle` goes, which is why it is a size and not a style: it is
        /// not text, it is a picture, and it is the one place in the app where something is drawn
        /// large simply to be looked at.
        public static let signInMark: CGFloat = 56

        /// The mark over a welcome slide. A placeholder for now — the illustrations that go
        /// there are not drawn yet — and sized as the picture it will be rather than as the
        /// symbol standing in for it, so the layout does not shift when they arrive.
        public static let welcomeMark: CGFloat = 132

        /// One of the dots under the welcome slides. Small: it says where you are, it is not a
        /// control anybody aims at — the tap target around it is a full `minimumTapTarget`.
        public static let pageDot: CGFloat = 8

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

        /// The pictures the user compares to verify a device.
        ///
        /// Large, and deliberately so: the entire security of the exercise is that somebody
        /// actually *looks* at them and at the seven on the other screen. An emoji at body size is
        /// something the eye skims past, and skimming is exactly the failure this screen exists to
        /// prevent.
        public static let verificationEmoji: CGFloat = 40

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
        /// This is a *ceiling*, not a size: the circle takes the width it is given and stops
        /// here. On a phone it is the screen minus a hair of margin either side; the cap only
        /// bites on an iPad or a Mac window, where a preview the size of a dinner plate would
        /// stop being a preview and start being a mirror.
        public static let videoNoteCamera: CGFloat = 440

        /// How wide the line under the camera may run — "let go to send", or the two sentences it
        /// takes to say the camera is not allowed. Narrower than the circle above it on purpose:
        /// text that reaches further than the thing it is about looks like it belongs to the
        /// screen rather than to the picture.
        public static let videoNoteHint: CGFloat = 300

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

        /// The bar on the storage screen that shows what is taking the room up.
        ///
        /// Thick enough that a sliver of a few megabytes beside a few hundred is still a
        /// visible band of colour rather than a hairline, and thin enough to read as a
        /// measurement rather than as a block of decoration.
        public static let storageBar: CGFloat = 16

        /// The narrowest a band on that bar may be drawn.
        ///
        /// A category with a hundredth of the space still exists, and a bar that rounds it to
        /// nothing is answering "what is on this device" with a lie. It is rounded *up* to a
        /// mark you can see, which costs the largest band a couple of points it will not miss.
        public static let storageBarLeast: CGFloat = 4

        /// The room-list column, on the platforms that show it beside a conversation — a Mac
        /// window, and an iPad wide enough to keep the split view open.
        ///
        /// Given as an explicit min/ideal/max rather than left to itself. A `NavigationSplitView`
        /// *derives* the sidebar's width from its content's ideal width, and settings is pushed onto
        /// this same column — a `Form` onto a `Form` — so the width it derives from changes the
        /// instant a settings row is opened, and the column jumps under the room list.
        ///
        /// This was also once written down as the cause of the macOS settings hang, and it is not.
        /// The hang survives an absolute width and survives no width at all; it was one property in
        /// `SettingsView`, and the note is left here because a wrong cause in a comment costs the
        /// next person the same afternoon. See `SettingsView.onClose`.
        public static let sidebarMinimum: CGFloat = 280
        public static let sidebarIdeal: CGFloat = 320
        public static let sidebarMaximum: CGFloat = 400

        /// The list of things you can do to a message — see `MessageMenu`.
        ///
        /// Narrow on purpose, and narrower than the screen by a long way: it is a column of
        /// short verbs, and a menu that runs the full width of an iPhone stops reading as a
        /// menu and starts reading as a page. The verbs are one word each — the widest of them
        /// is "Переслать" — so the width is set by the shape a menu should be and not by the
        /// text, which has room to spare at this size in both languages.
        public static let menuWidth: CGFloat = 240

        /// One line of that list.
        ///
        /// The same 44 the rest of the app uses for anything a finger has to find. It was 48
        /// for a day, on the argument that a floating panel wants more air than a settings
        /// screen — and what the four extra points actually bought was distance between verbs
        /// that belong together. The air a menu needs is *around* the list, at its top and its
        /// bottom and its sides, and that is where it is now spent.
        public static let menuRow: CGFloat = 44

        /// The icon column down the leading edge of the menu. Wide enough that a pin, a trash
        /// can and a bent arrow all sit on the same vertical line — they are drawn at different
        /// widths, and left to themselves the words beside them would not line up.
        public static let menuIcon: CGFloat = 26

        /// The bar of emoji above the lifted message.
        ///
        /// A fixed number rather than a measured one, and that is load-bearing: the menu works
        /// out where to put the message *before* anything is drawn, and it can only do that if
        /// it already knows how tall the bar above it will be.
        public static let reactionBar: CGFloat = 52

        /// One emoji in that bar, and one cell in the grid the "+" opens. A round tap target
        /// of the usual size, which is also what makes the grid come out square.
        public static let reactionCell: CGFloat = 44

        /// The panel of every emoji, when six is not the one you wanted. Tall enough to show
        /// four rows at once — fewer and it reads as a scrap of a keyboard rather than a
        /// keyboard — and short enough to leave the message it belongs to on screen.
        public static let emojiPanel: CGFloat = 268

        /// And how wide it is — half again as wide as the menu of verbs beside it.
        ///
        /// The only part of the menu that is not a column of words. It is a *grid*, and a grid
        /// is measured in cells: at the menu's own 240 points it fits five emoji to a row, so a
        /// category of a hundred characters arrives as a ribbon twenty rows long that has to be
        /// scrolled past to reach the next one. At 360 it fits seven, which is most of a
        /// category in a screenful and close to the row the system's own picker gives.
        ///
        /// It is capped against the screen where it is used, so on the narrowest phone it is
        /// simply as wide as there is room for — see `MessageMenuLayout.emojiWidth`.
        public static let emojiPanelWidth: CGFloat = menuWidth * 1.5
    }

    /// The colours of the storage bar, which are the one place in the app that colour carries
    /// information rather than tone.
    ///
    /// Deliberately not the accent. The accent is the user's, it means "press this", and it
    /// changes under them — a chart whose key changed colour when somebody picked a new tint
    /// would be telling them something different every time. These are fixed, in the system's
    /// own palette, so they follow light and dark and increased contrast without our help.
    ///
    /// A *list*, not three named colours, and taken in order: the categories are the bands, and
    /// the bands are however many categories there turn out to be. A fourth kind of data can be
    /// added to `StorageKind` without anybody having to remember there was a colour to choose for
    /// it — it takes the next one here. The order is fixed and the assignment is positional, which
    /// is the one thing that must not drift: a band that changed colour between two openings of
    /// the screen would be a chart telling a different story each time.
    public enum Storage {
        public static let bands: [Color] = [.red, .yellow, .green, .blue, .purple]

        /// The colour of the nth band. Wraps rather than runs out — a sixth category getting the
        /// first colour again is worse than a sixth category getting no colour at all, but only
        /// just, and both are better than a crash on a screen about disk space.
        public static func band(_ index: Int) -> Color {
            bands[index % bands.count]
        }
    }
}

public extension ShapeStyle where Self == Color {
    /// The fill behind a message someone else sent.
    ///
    /// A neutral, hierarchical fill rather than a chosen grey, so it follows the
    /// system into dark mode and into increased-contrast mode without our help.
    static var incomingBubble: Color {
        // Lighter in the light appearance than in the dark one, and the asymmetry is the point.
        // This used to be one number — `Color.primary.opacity(0.08)` — which is tidy and is not
        // the same grey twice: eight percent of white on a dark page is a whisper, and eight
        // percent of black on a white one is a distinctly grey slab. The two appearances were
        // asking for the same ink and getting different weights of it, and the light one came out
        // heavy: a column of grey blocks down one side of a white screen.
        //
        // So the light appearance gets five percent, which is the same *whisper* rather than the
        // same number, and the dark one is left exactly as it was.
        Color.adaptive(light: Color.black.opacity(0.05), dark: Color.white.opacity(0.08))
    }

    /// The same fill, for a conversation standing on a wallpaper.
    ///
    /// Opaque, which is the whole difference. Every other fill in this app is a percentage of the
    /// foreground colour, so that it follows the appearance and the contrast settings without being
    /// maintained — and a percentage is a *translucency*, which over the app's own flat page is
    /// invisible as such and over somebody's photograph is the photograph showing through the words.
    /// So on a wallpaper the bubble stops being a tint of the page and becomes a surface on top of
    /// it: near-white in the light appearance, a dark grey in the dark one, both opaque.
    static var incomingBubbleOnWallpaper: Color {
        Color.adaptive(light: Color(white: 0.99), dark: Color(white: 0.17))
    }

    /// Your own bubble on the colourless theme, over a wallpaper — the same argument as above, a
    /// tone heavier, so that the two sides of the conversation still read as one material told
    /// apart by weight.
    static var ownBubbleOnWallpaper: Color {
        Color.adaptive(light: Color(white: 0.87), dark: Color(white: 0.30))
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


public extension Color {
    /// One colour for the light appearance and another for the dark one.
    ///
    /// SwiftUI has no way to say this: `Color.primary.opacity(_:)` follows the appearance, but it
    /// follows it with the *same* number on both sides, and a grey that is right in the dark can be
    /// half again too heavy in the light. Everything else in this file is a system colour or a
    /// hierarchical style precisely so that the system does this for us — this is the one place
    /// where the two sides genuinely want different values, so it is spelled out once, here, and
    /// resolved by the platform's own dynamic-colour machinery rather than by reading the scheme in
    /// a view.
    static func adaptive(light: Color, dark: Color) -> Color {
        #if canImport(UIKit)
        Color(UIColor { traits in
            UIColor(traits.userInterfaceStyle == .dark ? dark : light)
        })
        #elseif canImport(AppKit)
        Color(NSColor(name: nil) { appearance in
            NSColor(appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light)
        })
        #else
        light
        #endif
    }
}
