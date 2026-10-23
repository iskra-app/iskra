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
        /// The bottom corners of an album's pictures when words follow them: the pictures end and
        /// the caption begins, and a full bubble's curve there reads as two bubbles stacked.
        public static let pictureAboveCaption: CGFloat = 8

        /// The corner of an app icon drawn at some size — see `Size.appIconTile`.
        ///
        /// A proportion rather than a constant, because that is what the home screen's corner
        /// is: iOS rounds an icon to a fixed *fraction* of its side, so a tile drawn with any
        /// fixed radius reads as the right picture in the wrong shape. The fraction is the one
        /// the system uses.
        public static func appIcon(side: CGFloat) -> CGFloat { side * 0.2237 }
        public static let card: CGFloat = 16
        public static let control: CGFloat = 12
        /// The white card the QR screen turns in the hand — `QRCodeSheet`. Rounder than `card`,
        /// because it is held up as an object of its own and not set into a list.
        public static let qrCard: CGFloat = 28

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

    public enum Opacity {
        /// A warning's colour spread under its words — enough to be told apart from an ordinary
        /// notice at a glance, little enough that the words on it stay the words' own colour.
        public static let warningWash: Double = 0.14
        /// The pill under the open folder tab — there, and only just. See `FolderTabs`.
        public static let selectedTab: Double = 0.2
        /// What is left of the conversation under the title bar and the composer, at the far end
        /// of its fade. Not nothing: faded all the way out, the edges read as two solid bands
        /// cut across the room rather than as messages passing underneath. See `RoomView`.
        public static let timelineFadeFloor: Double = 0.3
        /// The words of a form's button on a Mac while it is held down, and while it cannot be
        /// pressed at all. See `FormRows`.
        public static let rowPressed: Double = 0.6
        public static let rowDisabled: Double = 0.4
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
        /// Between the pictures of an album — a hairline of the bubble showing through, as in
        /// Telegram, so the set reads as one thing made of several. See `AlbumMosaic`.
        public static let albumGap: CGFloat = 2
        /// Around a caption under a picture, inside the bubble's own `tight` frame — so that the
        /// words stand exactly as far from the bubble's edges as a text message's do (`roomy` to the
        /// sides, `normal` above and below; see `MessageBubble`).
        public static let captionHorizontal: CGFloat = roomy - tight
        public static let captionVertical: CGFloat = normal - tight
        /// Between an album's pictures and the caption under them — more than a single photo
        /// gives, because a mosaic is busy right up to its edge.
        public static let albumCaptionTop: CGFloat = normal

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
        /// that holding is a decision. Nothing is drawn during it: the bubble used to sink through
        /// this quarter second as a countdown, and a message that changes shape under a finger is
        /// exactly what the menu must not show.
        public static let menuLift: TimeInterval = 0.25

        /// How long a finger stays on a chat in the list before the peek lifts it — see `ChatPeek`.
        ///
        /// Longer than `menuLift`, because the two rows are not asking the same question. A
        /// message is held by somebody who has decided to do something to it; a chat row is
        /// *tapped* by nearly everyone, nearly every time, and a thumb that is merely slow on its
        /// way to a tap should open the chat and not a preview of it. The system's own half second.
        public static let peekLift: TimeInterval = 0.5

        /// The menu arriving: the bubble rising off the page, the bar and the list opening
        /// around it. A spring, because the lift is the one moment in a conversation where the
        /// app is *picking something up*, and things that are picked up have weight.
        ///
        /// Telegram's spring, number for number. Its context menu runs every part of the opening on
        /// one `CASpringAnimation` (`ContextControllerExtractedPresentationNode`): mass 5, stiffness
        /// 900, damping 104 — a damping ratio of 0.775 — and then *played faster*, squeezed from its
        /// natural settling time of 0.741 s into 0.42 s. Squeezing a spring in time is the same as
        /// making it stiffer at the same ratio: it comes out as a response of 0.265 s.
        ///
        /// This used to be `.spring(duration: 0.42, bounce: 0.12)`, which reads as the same
        /// thing and is not: SwiftUI's `duration` is the *response*, not the time to settle, so it
        /// was a spring more than half as slow again as Telegram's — and with less damping. The
        /// message drifted up into the menu where Telegram's snaps into it and lands.
        public static let menuOpens: Animation = .spring(response: 0.265, dampingFraction: 0.775)

        /// The pill under the folder tabs sliding from one tab to the next, and the chats of the
        /// new tab sliding in after it — see `FolderTabs` and `RoomListView.folderSelection`.
        public static let folderSwitches: Animation = .spring(duration: 0.35, bounce: 0.15)

        /// And the menu going away: no spring at all. Telegram puts a message back on a plain
        /// 0.2 s ease-in-ease-out — a thing being put down is not thrown.
        public static let menuCloses: Animation = .easeInOut(duration: 0.2)

        /// The verbs becoming visible as they unfold out of the message: almost at once. Telegram
        /// fades its actions in over 0.05 s, so the eye follows the *unfolding* and never watches a
        /// list fade up.
        public static let menuListShows: Animation = .linear(duration: 0.05)

        /// How far into the flight the menu's glass is left empty before what is on it appears.
        ///
        /// The capsule and the panel arrive first, as shapes — glass growing out of the message's
        /// corner with nothing on it yet — and the emoji and the verbs land on them once they have
        /// mostly opened. Both at once is a menu that *scales its words*: six lines of text
        /// swelling from a dot read as the list being zoomed, and an emoji at a tenth of its size
        /// is a smudge. Empty glass growing reads as a surface opening, and then there is
        /// something on it. Most of the way through the opening spring's response, which is when
        /// the glass is nearly its full size.
        public static let menuFills: Duration = .milliseconds(150)
        /// How often the spark on an empty screen blinks, and how long its eyes stay shut —
        /// `BlinkingSpark`, and the web client's watermark, which keeps the same rhythm.
        public static let blinkEvery: Duration = .seconds(4)
        public static let blinkShut: Duration = .milliseconds(150)

        /// What is on the glass appearing, once it is there — quick, it is only being shown.
        public static let menuContentShows: Animation = .easeOut(duration: 0.15)

        /// The bar of emoji becoming visible as it unrolls — Telegram's 0.15 s.
        public static let menuBarFades: Animation = .easeOut(duration: 0.15)

        /// One emoji popping into the bar, Telegram's 0.4 s spring from almost nothing, with a
        /// little bounce: these are the most pressable things in the app, and they are allowed to
        /// say so as they arrive. Staggered by the bar — see `ReactionBar.popDelay`.
        public static let reactionPops: Animation = .spring(duration: 0.4, bounce: 0.3)

        /// Reactions arriving and leaving.
        public static let reaction: TimeInterval = 0.25

        /// The furniture rearranging itself: the composer growing a strip, the send button taking
        /// the microphone's place, the search field opening, the jump-to-newest button appearing.
        ///
        /// Written out as a bare `0.25` in nine different places, which is not nine decisions — it
        /// is one decision made once and copied, and the ninth copy is where somebody types `0.3`
        /// by accident and nobody ever notices that one control moves differently from the rest.
        public static let chrome: TimeInterval = 0.2

        /// A message arriving in the conversation — one you have just sent, or one that has
        /// just been said to you.
        ///
        /// A spring. A message arriving has weight and should land rather than glide in. The
        /// bounce is small — a bubble that wobbles under the words above it is a toy — and it is
        /// there so the arrival reads as a thing put down rather than as a fade somebody might
        /// miss.
        ///
        /// It is carried by the row itself, in `MessageArrival`, and by nothing else. This is
        /// the only animation left in a conversation: a message that is merely *changing* — read,
        /// reacted to, edited, deleted — changes at once.
        public static let arrival: Animation = .spring(duration: 0.32, bounce: 0.18)

        /// A message opening its place at the foot of the conversation — the whole column moving up
        /// by its height, and the message coming up from under the composer into the room it made.
        ///
        /// Telegram's numbers, taken as they are: `ChatMessageTransitionNode` moves a sent message
        /// vertically on this bezier over 0.3 s. It starts slowly and then commits — the column is
        /// seen to *make room* before the message is seen to take it — which is the difference
        /// between a message arriving and a list being redrawn. See `MessageArrival`.
        public static let messageMakesRoom: Animation = .timingCurve(0.199, 0.011, 0.279, 0.910,
                                                                     duration: 0.3)

        /// A message of ours travelling across from the composer to its own side of the screen.
        ///
        /// Telegram's horizontal curve for the same transition, deliberately not the vertical one:
        /// it is fast off the mark and long in the settling, so the words leave the box the instant
        /// send is pressed and ease into the bubble rather than arriving at both ends at once.
        public static let messageCrosses: Animation = .timingCurve(0.23, 1, 0.32, 1, duration: 0.3)

        /// …and up out of the field, from the line the words were typed on to the foot of the
        /// conversation. The same shape as `messageCrosses` — off at once, long in the settling —
        /// and a little longer, so the rise is seen as one movement with the column making room
        /// rather than as a jump to where the column ends.
        public static let messageLeavesComposer: Animation = .timingCurve(0.23, 1, 0.32, 1, duration: 0.4)

        /// Somebody else's message coming up into the space the column has made for it. A fade, and
        /// a short one — Telegram's 0.2 s — because the movement is the column's; this only keeps
        /// the bubble from being seen to slide in solid from under the composer.
        public static let messageAppears: Animation = .easeOut(duration: 0.2)

        /// The date floating over a conversation coming in as the list starts to move — Telegram's
        /// 0.3 s (`ChatMessageDateHeader.updateFlashing`).
        public static let floatingDateIn: Animation = .easeOut(duration: 0.3)

        /// …and going once the list has come to rest, a little slower — Telegram's 0.4 s.
        public static let floatingDateOut: Animation = .easeIn(duration: 0.4)

        /// How long the list has to be still before the floating date goes. Long enough that a
        /// flick followed by a second flick does not blink it out between them.
        public static let floatingDateLingers: Duration = .milliseconds(800)

        /// How long the conversation stays pinned to its end after a message has landed there.
        ///
        /// A row is not its final height when it is inserted — the picture in it arrives, the
        /// quote above it resolves — so being sent to the end once lands short of it. Long enough
        /// for an attachment to size itself; short enough that it is over before anybody could
        /// want to scroll away. See `RoomView.followsEnd`.
        public static let endIsHeld: Duration = .milliseconds(700)

        /// How long the reader's place, noted when a message lands below them, may still be put
        /// back. The message makes the conversation taller within a frame or two; a note older than
        /// this is about a moment that has passed, and putting it back moves the reader somewhere
        /// they no longer are. See `RoomView.held`.
        public static let placeIsHeld: Duration = .milliseconds(600)

        /// How often the end is asked for again while it is being held. See
        /// `Timing.endIsHeld` and `RoomView.followEnd()`.
        public static let endIsCheckedEvery: Duration = .milliseconds(50)

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
        ///
        /// It was two and a half seconds, which on a dark appearance is two and a half seconds of a
        /// black screen; it is shorter now, and the wait shows a spinner after `roomWaitIsShown`.
        public static let roomWaitsToBeSeen: Duration = .milliseconds(1500)

        /// How long a room may stay blank before the wait for it is shown — see
        /// `RoomView.isWaitingVisibly`.
        public static let roomWaitIsShown: Duration = .milliseconds(400)

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
        /// It was a quarter of a second after that, which kept the widest margin between a hold
        /// and the tap that flips the button between voice and video — and the quarter of a
        /// second was itself the lag people felt: nothing on screen moved until it was over. Now
        /// the button answers the touch itself (it swells, and the phone ticks — see
        /// `MessageComposer.recordButton`), and this is what is left of the wait: as short as a
        /// deliberate tap allows, which in practice is well under 150 ms.
        public static let holdBegins: Duration = .milliseconds(150)

        /// How long a press on the record button has to last before the microphone is woken for
        /// it — longer than a tap, so switching between voice and video wakes nothing.
        public static let prewarmAfter: Duration = .milliseconds(90)

        /// How long one slide of the welcome carousel stands still before the next one comes.
        ///
        /// Long enough to read two lines without hurrying — the slides are the app's only pitch,
        /// and a carousel that moves while somebody is still reading it is a carousel they fight.
        /// Short enough that a person who is not reading gets through all six on the way to the
        /// button. See `WelcomeView`, which stops the timer at the last slide rather than looping:
        /// once everything has been said, the screen waits.
        public static let welcomeSlide: Duration = .seconds(5)

        /// The pause between the question and the answer in the first run's preview.
        ///
        /// The two lines are a conversation, so they arrive the way a conversation does: one, and
        /// then the other, with long enough between them to be an answer rather than a second half
        /// of the same breath. Short enough that somebody who came to pick a colour is not kept
        /// waiting for the thing they are picking it against.
        public static let previewReplies: Duration = .milliseconds(450)

        /// One first-run screen giving way to the next.
        ///
        /// Half a second, and no bounce. A whole screen is the largest thing this app ever
        /// animates, and weight that is charming on a message bubble is a wobbling wall at this
        /// size — so it is a spring for the ease alone: quick off the mark, and settling rather
        /// than stopping. See `AnyTransition.onboardingStep`.
        public static let stepChanges: Animation = .spring(duration: 0.45, bounce: 0)

        /// One frame at sixty hertz.
        ///
        /// Not a delay: it is the frame in which a thing is drawn *where it starts*, so that the
        /// animation asked for immediately afterwards has somewhere to begin. `onAppear` runs
        /// inside the same pass that first lays a view out, and SwiftUI does the sensible thing
        /// with an animation whose initial value it has never drawn — it collapses the two into
        /// one render and puts the view straight at its final place. See `MessageArrival.land()`,
        /// which is where this was learned, and `GreetingStep`, which learned it second-hand.
        public static let aFrame: Duration = .milliseconds(16)

        /// How far apart two things that arrive together are let land.
        ///
        /// A face and the hello under it, two lines of a conversation that has not happened: they
        /// belong to one event, so they must not arrive at one instant — everything landing on the
        /// same frame reads as a screen being switched on, and the point of animating any of it is
        /// that something is *happening*. Small enough that nobody counts it out.
        public static let stagger: TimeInterval = 0.12

        /// How long the hello stands on screen before the first run moves on.
        ///
        /// Three seconds: long enough to be read and to register as the app saying something
        /// rather than as a flash between two screens, short enough that nobody waits for it. It
        /// is a greeting and not a step, so there is nothing on it to press — see `FirstRunView`.
        public static let greeting: Duration = .seconds(3)
    }

    /// Things drawn at another size than they are, as feedback — named here for the same reason
    /// every spacing is.
    public enum Scale {
        /// How far the first run's preview bubble swells when a new accent lands on it.
        ///
        /// Four percent, and upward. It is the smallest movement that is still seen on a bubble
        /// the size of one line of text, and it is the right size for what it says — the reply did
        /// not *do* anything, it was repainted, and a bubble that jumped would be claiming more
        /// than that. See `AppearanceStep.nod()`.
        public static let nod: CGFloat = 1.04
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

        /// How dark the conversation goes behind an open message menu.
        ///
        /// Much darker than `wash`, which is a tint for a panel and not a curtain: at 0.12 the
        /// room behind the menu was still a room, and the bubbles in it competed with the one
        /// that had been lifted out of it. On a Mac, where the curtain is the *only* thing
        /// between the menu and the conversation (there is no blur there, see
        /// `MessageMenuOverlay.scrim`), it has to do all of that work by itself.
        public static let menuScrim: Double = 0.4

        /// How dark the conversation goes behind an open photograph, under its blur — Instagram's
        /// viewer, where the chat is still there but is no longer something to read. Dark enough
        /// that the white header and footer stay legible over whatever colours the chat had.
        public static let viewer: Double = 0.65

        /// How much of the blur is laid over what is behind the photograph. Neither platform lets a
        /// material's radius be chosen, so a lighter blur is the blurred layer let partly through:
        /// at 1 the chat is gone, lower and its shapes stay faintly there behind the picture.
        public static let viewerBlur: Double = 1
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

        /// A face in the favourites widget: four fit a small widget with their names under them,
        /// eight a medium one.
        public static let widgetFace: CGFloat = 48
        /// The face on a Live Activity's lock-screen banner and in the expanded Dynamic Island.
        public static let activityFace: CGFloat = 44

        /// The face beside a conversation in the chat list.
        ///
        /// Bigger than `avatar`, and it is a size of its own rather than a bump to that one
        /// because `avatar` is also worn by the members of a room — a list of *names*, where the
        /// picture is an ornament beside the word that matters. In the chat list the picture is
        /// how a conversation is found: the eye goes down the column of faces, not down the column
        /// of names, and at 40pt it was doing that work at the size of a footnote.
        public static let roomAvatar: CGFloat = 56
        /// The same face in the Mac's own sidebar, which is a narrow column read down its length:
        /// Telegram's size there, and what lets two lines of the last message sit beside it without
        /// the row growing past the face.
        public static let roomAvatarCompact: CGFloat = 48
        /// The smallest the avatar cropper's window is on a Mac — `AvatarCropper`.
        public static let avatarCropper: CGFloat = 480
        /// A Mac sheet that is mostly a list — "New chat", "who reacted": a `List` asks for no size
        /// of its own, so the sheet has to, or it opens with nothing between its title and Cancel.
        public static let listSheetWidth: CGFloat = 440
        public static let listSheetHeight: CGFloat = 520
        /// The sticker picker on a Mac: a popover over the composer, like the reaction picker, not a
        /// sheet the size of the window.
        public static let stickerPopoverWidth: CGFloat = 360
        public static let stickerPopoverHeight: CGFloat = 420

        /// The height of the unread badge in the chat list, and the width of the "@" beside it —
        /// one number, so the circle and the capsule stand exactly level.
        public static let unreadBadge: CGFloat = 20
        /// The dot that says "unread" with no number to show. Off the four-point grid, and kept
        /// there: it is the size the list has always drawn, moved here from a literal in the row
        /// rather than redesigned in passing.
        public static let unreadDot: CGFloat = 10

        /// How far the chats of a newly opened folder travel in from the side of the tab they
        /// came from. Short on purpose: it says which way you went, it is not a page being turned.
        public static let folderSlide: CGFloat = 40
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

        /// One sticker in the sheet that sends them: four across on a phone with room between,
        /// and big enough to tell one face from another without opening it.
        public static let stickerCell: CGFloat = 72

        /// A pack's picture in the row of tabs along the top of that sheet.
        public static let stickerTab: CGFloat = 32

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
        /// The ring over a photo or video of ours that is still going up — `UploadRing`. Telegram's
        /// is 48 on a photo, and 48 is also comfortably more than the tap floor below, which
        /// matters because the cross in it is a button.
        public static let uploadRing: CGFloat = 48
        /// One of the round glass buttons under a person's portrait — `ProfileActionTile`. A size a
        /// thumb lands on without aiming, with the word under it rather than inside.
        /// On a Mac, smaller: a pointer needs no thumb's room, and at the phone's size four of them
        /// under a name in a 320-point column read as the page's headline.
        #if os(macOS)
        public static let profileAction: CGFloat = 40
        #else
        public static let profileAction: CGFloat = 56
        #endif
        /// The QR code on its own screen — `QRCodeSheet`. Large enough for a camera across a table,
        /// small enough to leave the name and the face above it on a small phone.
        public static let qrCode: CGFloat = 240
        /// How wide that card is. The code fills it less the margins, so this is what makes it
        /// "large": about the width of a phone less a hand's grip on either side.
        public static let qrCardWidth: CGFloat = 320
        /// The face at the top of the card.
        public static let qrCardFace: CGFloat = 72
        /// The spark on the back of the card — wider than the card itself, so that its rays run
        /// off the edges and it reads as a mark printed across the card, not a badge placed on it.
        public static let qrCardSpark: CGFloat = 448
        /// How far left of centre that spark sits: about a third of the card's width.
        public static let qrCardSparkShift: CGFloat = 96
        /// The distance between two sparks of the rainbow watermark — `HoloWatermark`. Small enough
        /// to read as a texture and not as a pattern of separate pictures.
        public static let watermarkStep: CGFloat = 16
        /// The spark on an empty screen — `BlinkingSpark`; the web client's `--size-watermark`.
        public static let watermark: CGFloat = 128
        /// A chat's face in the share sheet's grid — four to a row on a phone, Telegram's size.
        public static let shareFace: CGFloat = 60
        /// How wide a poll's bubble is. Fixed, not hugging its words: the bars are a comparison,
        /// and a bar is only comparable to another drawn against the same width.
        public static let poll: CGFloat = 264
        /// The thickness of a result bar under an answer.
        public static let pollBar: CGFloat = 4
        /// Nothing tappable is ever smaller than this. Apple's floor, and ours.
        public static let minimumTapTarget: CGFloat = 44
        /// The column a symbol stands in at the start of a form row on a Mac (`FormRows.swift`):
        /// as wide as the widest symbol the rows use, so every title starts at the same place.
        public static let rowIcon: CGFloat = 20

        /// A colour to choose the app's accent from, on the appearance screen. A full tap
        /// target: a swatch is a button, and a colour you have to aim at is a colour you
        /// pick by accident.
        public static let swatch: CGFloat = 44

        /// The accent's circles in particular. On a Mac they are a row of dots at the end of a
        /// settings line: a pointer needs no fingertip of room, and eight 44-point discs in a
        /// settings card read as buttons shouting.
        #if os(macOS)
        public static let accentSwatch: CGFloat = 16
        #else
        public static let accentSwatch: CGFloat = swatch
        #endif

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

        /// A music file's bubble: how wide its name and bar are at least, and how tall the strip
        /// the bar is dragged along — taller than the bar, so a thumb can find it.
        public static let audioTrack: CGFloat = 160
        public static let audioScrubber: CGFloat = 20
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
        /// The same for an album, which is allowed a little more: it is several pictures, and
        /// squeezed into half the screen each of them would be cropped down to a strip.
        public static let albumHeightFraction: CGFloat = 0.6

        /// And a ceiling on both, in points, under the fractions: half of an iPad or of a tall Mac
        /// window is still a portrait photo that fills the view, and the conversation it was sent
        /// in is gone again. A bit taller than `picture` is wide, so a portrait photo still reads
        /// as one — at most one and a seventh of its width, and the caption, which is not the
        /// picture, comes under it and is not counted.
        public static let pictureMaxHeight: CGFloat = 320

        /// The smallest an opened video is allowed to be. It matters on the Mac, where the
        /// viewer is a sheet rather than the whole screen and would otherwise shrink to the
        /// size of the spinner it starts out showing.
        public static let viewer: CGFloat = 480

        /// The black between two pages of the media viewer while one slides over the next —
        /// Telegram's gallery leaves a gap, so two photographs never touch edge to edge.
        public static let galleryPageGap: CGFloat = 20

        /// How far a photograph sits in from the edges of the viewer before it is zoomed — Instagram's
        /// picture, which floats over the blurred conversation rather than touching the screen's
        /// sides. Zoomed in, it is the screen's again.
        public static let galleryInset: CGFloat = 16

        /// The strip of little pictures along the foot of the viewer: a tile, and the wider one
        /// the current picture gets, so the strip says where in the room you are.
        public static let galleryThumbnail = CGSize(width: 28, height: 40)
        public static let galleryThumbnailCurrent: CGFloat = 56

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

        /// One line of `.body` at the default text size, rounded to the grid — what a one-line
        /// bubble is as tall as. Scaled from there with Dynamic Type (see
        /// `MessageBubble.minimumContentWidth`).
        public static let bodyLine: CGFloat = 24

        /// The app's icon at the top of the opening screen — the one picture on it, so it can be
        /// big enough to be the screen's subject.
        public static let signInLogo: CGFloat = 112

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

        /// A pasted or dropped picture waiting in the composer. Big enough to tell one screenshot
        /// from another at a glance, small enough that four of them are still one row.
        public static let attachmentTile: CGFloat = 64

        /// A colour to draw or write in, in the photo editor. Drawn smaller than the tap target it
        /// sits in, so that six of them fit a phone's width with room between.
        public static let inkSwatch: CGFloat = 28
        /// How far each arm of a corner of the crop frame reaches along its edges.
        public static let cropCorner: CGFloat = 20

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
        /// they watch a spinner. And not one screenful either, which is what it was: a flick
        /// travels further than that, so the conversation hit its top and bounced *before* the
        /// page landed, and the page then arrived under a scroll view in the middle of its bounce
        /// — the jump people kept reporting. Several screens of slack means the history is in
        /// place long before a thumb can get there.
        public static let paginationReach: CGFloat = 2400

        /// How close to the newest message counts as standing on it — and therefore as having
        /// asked to be brought along when the next one arrives.
        ///
        /// Small, and much smaller than `paginationReach`, because it answers a different
        /// question. That one is generous on purpose: fetching early is free, and the cost of
        /// guessing wrong is a page nobody reads. This one decides whether to *move the screen
        /// under somebody's eyes*, and the cost of guessing wrong is losing their place in a
        /// conversation they were reading. A screenful of slack would do exactly that.
        public static let newestReach: CGFloat = 80

        /// How far the conversation has to be dragged back into its history before the keyboard
        /// goes down. Enough to be a decision, not a twitch of the thumb.
        public static let keyboardDismissDrag: CGFloat = 48

        /// How far the conversation takes to fade out under a bar — the same at the title bar and
        /// at the composer, so the two edges match.
        public static let timelineFade: CGFloat = 56

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

        /// The two side columns of a Mac window — the room list on the left and the chat's info on
        /// the right — fixed, and the same. Fixed, so a window resized gives and takes width from the
        /// conversation alone, and the same, so the conversation sits between two columns that match.
        public static let sideColumn: CGFloat = 320

        /// The least a Mac window may be: both side columns and the narrowest a conversation may be
        /// between them — so the info column can always be opened, however narrow the window is.
        public static let windowMinimum: CGFloat = 2 * sideColumn + conversationMinimum.width

        /// The widest a form may be on a Mac — settings and every page under it — with the form's own
        /// margin of 20 either side, so its cards come out about 470. The Mac's own grouped form
        /// stops at about 700, which in a window's wide column read as a page of banners rather
        /// than of settings; this is two thirds of it.
        public static let formCardMaximum: CGFloat = 508

        /// The Mac's About window: the About screen at the width of a phone's, tall enough for the
        /// version, the build and the links without scrolling.
        public static let aboutWindow = CGSize(width: 420, height: 640)

        /// The least a conversation may be squeezed to on a Mac, with the info column open beside
        /// it. With the column shut, the conversation takes the column's width as well, so the
        /// window never shrinks below `windowMinimum` whichever is showing — see
        /// `InfoColumn.conversationMinimumWidth`. Squeezed with nothing to hold it, a chat became a
        /// column of one word a line.
        ///
        /// Put on the chat and on the empty column's spark, never on the column around them: there,
        /// it was re-measured from the chat on every frame of a resize, and AppKit ended the app
        /// (`Iskra --probe-resize` reproduces it).
        public static let conversationMinimum = CGSize(width: 420, height: 450)

        /// The least height a Mac window may be.
        public static let windowMinimumHeight: CGFloat = 450

        /// The least height to put on the room list so that the window comes out
        /// `windowMinimumHeight`. The window's title band (52 points) is counted three times on
        /// the way up — by the split view round the columns, again by the one the info column hangs
        /// on, and once more by the window itself (measured with `Iskra --probe-resize heights`) —
        /// so a list asked for 450 held the window at 606. The same double count as the width's,
        /// paid for the same way: see `InfoColumn.conversationMinimumWidth`.
        public static let columnMinimumHeight: CGFloat = windowMinimumHeight - 3 * 52

        /// The list of things you can do to a message — see `MessageMenu`.
        ///
        /// Narrow on purpose, and narrower than the screen by a long way: it is a column of
        /// short verbs, and a menu that runs the full width of an iPhone stops reading as a
        /// menu and starts reading as a page. The verbs are one word each — the widest of them
        /// is "Переслать" — so the width is set by the shape a menu should be and not by the
        /// text, which has room to spare at this size in both languages.
        /// Narrower on a Mac, where the menu is pointed at rather than touched and the text is
        /// smaller — the phone's size there looked like a sheet, not a menu.
        #if os(macOS)
        public static let menuWidth: CGFloat = 200
        #else
        public static let menuWidth: CGFloat = 240
        #endif

        /// One line of that list.
        ///
        /// The same 44 the rest of the app uses for anything a finger has to find. It was 48
        /// for a day, on the argument that a floating panel wants more air than a settings
        /// screen — and what the four extra points actually bought was distance between verbs
        /// that belong together. The air a menu needs is *around* the list, at its top and its
        /// bottom and its sides, and that is where it is now spent.
        /// A pointer needs no 44-point target: on a Mac a row is the height of a menu item there.
        #if os(macOS)
        public static let menuRow: CGFloat = 32
        #else
        public static let menuRow: CGFloat = 44
        #endif

        /// The icon column down the leading edge of the menu. Wide enough that a pin, a trash
        /// can and a bent arrow all sit on the same vertical line — they are drawn at different
        /// widths, and left to themselves the words beside them would not line up.
        public static let menuIcon: CGFloat = 26

        /// The chat a long press lifts out of the chat list — see `ChatPeek`.
        ///
        /// Ceilings, not sizes. On a phone the screen is smaller than both and the card takes what
        /// the menu under it leaves; on an iPad or a Mac it stops at roughly a phone's worth of
        /// conversation, because a peek the size of the window is not a peek, it is the room.
        public static let peekWidth: CGFloat = 440
        public static let peekHeight: CGFloat = 640

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

        /// A group's heading in that panel — fixed, so where each group starts can be worked out
        /// rather than measured (`EmojiPanel.offset(of:)`).
        public static let emojiHeader: CGFloat = 28

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
