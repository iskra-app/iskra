import SwiftUI
import PhotosUI
import IskraCore
import IskraDesign

/// One conversation: the messages, and the box you type into.
public struct RoomView: View {
    @State private var timeline: TimelineStore
    @State private var draft = ""
    /// Recording a round video message.
    ///
    /// The recorder lives here and not in the sheet that shows the camera, because the gesture
    /// that drives it starts *outside* the sheet: the user holds the video button in the
    /// composer, the sheet comes up while their finger is still down, and lifting that finger is
    /// what sends. The sheet and the button therefore have to be talking about the same
    /// recorder, and only the screen can see both.
    @State private var videoNote = VideoNoteRecorder()
    @State private var isRecordingVideoNote = false

    /// Whether the finger that started the recording is still on the button.
    @State private var isHoldingVideoNote = false

    /// Whether the recording has been let go of — swiped up, or started from the sheet's own
    /// shutter. Either way, lifting the finger off the composer must not end it.
    @State private var isVideoNoteLocked = false

    /// The swipe up that would let go of the recording, as it is being made.
    ///
    /// Held here only to be carried across: the gesture belongs to the composer, and the composer
    /// draws its own pill from it — but the camera is a full-screen overlay laid *over* the
    /// composer, so during a video note that pill is behind a blur and the overlay has to draw
    /// its own above the shutter. It is the same swipe. The screen is the only place that can see
    /// both ends of it.
    @State private var lock = LockGesture()

    /// Recording a spoken message. Owned here for the same reason the camera is — the gesture
    /// that ends it is on a button, and the screen is what turns "let go" into "send".
    ///
    /// Unlike the camera, there is no sheet: a voice message has nothing to show, so the
    /// composer itself becomes the recording for as long as it lasts.
    @State private var voice = VoiceRecorder()

    /// Whether the user is answering somebody, or going back to change what they wrote. Held
    /// here rather than in the composer because both begin in the *timeline* — a menu item on a
    /// message — and only the screen can see both ends.
    @State private var composerContext: ComposerContext?

    /// The pinned messages, opened when the room has any. Built once and kept, for the same
    /// reason `details` is: `navigationDestination` re-evaluates on every redraw, and a fresh
    /// store each time would open a fresh timeline on every keystroke in the composer.
    @State private var pinned: PinnedStore?
    @State private var isShowingPinned = false

    /// The two attachment pickers, owned by the screen rather than by the composer that asks
    /// for them. The composer is a `safeAreaInset` floating over this view, and a
    /// presentation put there has already gone missing once (see `MessageComposer`); from
    /// the root of the screen both pickers open, which is what a picker has to do.
    @State private var isChoosingPhoto = false
    @State private var isChoosingFile = false
    @State private var isChoosingLocation = false
    @State private var pickedItem: PhotosPickerItem?

    /// Whether the conversation has been put where it belongs: on its newest message.
    ///
    /// A room opens at the bottom, and that has to be *done* rather than assumed. The
    /// timeline arrives empty and fills backwards from the newest message, so there is a
    /// stretch where the scroll view is at the top of a conversation that has barely
    /// started to exist — and everything that reacts to being near the top has to wait
    /// until this is true. See the pagination trigger below.
    @State private var hasAnchored = false

    /// Whether the room is still coming up, in which case it belongs at its newest message and is
    /// kept there — see the scroll-metrics observer. It stops the moment the reader touches the
    /// conversation, because from then on where it sits is their business and not ours.
    @State private var isOpening = true

    /// Whether the conversation has stopped assembling itself, and a change to it is therefore
    /// something that *happened* rather than the room still arriving.
    ///
    /// Nothing here may animate until this is true, and `hasLoaded` was not a strict enough
    /// answer. Opening a room is not one change but a dozen: the store publishes each batch of
    /// diffs on its own pass, then the events decrypt and their rows change height where they
    /// stand, then the pictures in them arrive and change height again — all of it after the
    /// first page is nominally loaded. With an animation scope around the list, every one of
    /// those passes set the whole column sliding to its new place, and fifteen messages sliding
    /// half a row at a time is exactly the twitching the reader sees as messages "flying in from
    /// above". So the room is drawn, flatly, and only then allowed to move.
    @State private var hasSettled = false

    /// Whether the conversation may be shown at all yet.
    ///
    /// This is the one that actually cures the twitching, and it took two wrong answers to find.
    /// A room is *drawn while it is still being fetched*: the store publishes rows on every batch
    /// of diffs, and the opening fetch is a loop — a page is 25 events and events are not
    /// messages, so it asks again, and again, until it has a screenful. Each of those turns is a
    /// network round trip, and each one put more messages on a screen the reader was already
    /// looking at. So the room opened showing its last message alone, at the bottom, and the rest
    /// of the conversation then piled in above it over the next second or two — which is exactly
    /// "they fly in from above", and no amount of taking animations away could fix it, because
    /// by the second attempt there was no animation left to take. It was never the animation. It
    /// was the room being shown half-built.
    ///
    /// So it is not shown half-built. The scroll view is laid out from the first row — invisible,
    /// so it anchors itself to the bottom and settles while nobody is watching — and the
    /// conversation appears when the store says it has one, whole and already in place.
    ///
    /// Once, and never again: a refill, a page of history, a message arriving must not hide the
    /// room. See `Theme.Timing.roomWaitsToBeSeen` for the ceiling on the wait.
    @State private var isRevealed = false

    /// What "arriving" means here, and why it is not "new".
    ///
    /// A time limit was not enough, and the reason is worth writing down: a conversation does
    /// not finish loading when it is first shown. The store hands over what it has, the room
    /// draws it, and the rest of the first screenful is then paginated in — page after page,
    /// each one arriving seconds later and each one, to a view watching only the clock, looking
    /// exactly like a message somebody has just sent. That is the "they still fly in" report:
    /// not the opening, but the history landing behind it.
    ///
    /// The honest test is not *when* a row appeared but *where*. History is added above what is
    /// already there; a new message is added past the end of it. So only the rows that come
    /// after the row that used to be last are arrivals, and everything else — a page of history,
    /// a re-keyed local echo, a room reloading itself — appears where it belongs, at once.
    ///
    /// The last row of the conversation as it stood on the previous pass is what "past the end"
    /// is measured from; `placedRows` is where the measuring happens.
    @State private var newestRowID: String?

    /// Whether the typing bubble is on screen — which follows `timeline.typing`, but not
    /// literally, and that is the cure for the bubble jerking.
    ///
    /// Typing notices are a stream of small lies told in good faith: the SDK reports "nobody"
    /// for a moment between two notices from the same person, and a bubble that obeyed every one
    /// of them came and went twice a second. So it comes at once, and goes only after
    /// `typingGrace` of nobody typing. The one exception is a message landing: then the thing it
    /// promised has arrived, and the bubble is taken away that same instant, with no animation,
    /// so the message rises into the place it stood instead of appearing under a bubble on its way
    /// out.
    @State private var showsTyping = false
    @State private var typingHide: Task<Void, Never>?

    private static let typingGrace: Duration = .milliseconds(700)

    /// Whether the room is *saying* it is fetching history, which is not quite the same as
    /// fetching it — see the spinner. The task is what puts the disc away again.
    @State private var isFetchingHistory = false
    @State private var spinnerRest: Task<Void, Never>?

    /// How long the spinner stays after the page has landed. Long enough to be seen and read as
    /// "there is more, it is coming", short enough that nobody is kept waiting by it — the page
    /// is already on screen underneath it.
    private static let spinnerRest: Duration = .milliseconds(450)

    /// Off, for now: the disc is hidden while the fetch it reports is reworked. Everything that
    /// drives it still runs, so turning it back on is this one line.
    private static let showsHistorySpinner = false

    /// A message arrived while the reader was somewhere else in the conversation.
    ///
    /// The other half of not dragging them to the bottom. Left on its own, "we no longer follow
    /// the newest message" would be a room that goes quiet on you: something is said, nothing
    /// moves, and you find out ten minutes later. So the room stays where it is and *offers*.
    @State private var hasUnseenBelow = false

    /// The colour the user chose. The pill that takes you to a new message is the one thing on the
    /// screen asking to be pressed, so it wears it — the same reason the send button does.
    @Environment(\.accent) private var accent
    @Environment(\.messageMenu) private var messageMenu

    /// A message the room has been asked to go to from *outside* the scrolling view — the pinned
    /// strip, or a search result the room was opened on.
    ///
    /// It has to be left here rather than acted on where it is raised: the `ScrollViewProxy` only
    /// exists inside `ScrollViewReader`, and the pinned strip is a `safeAreaInset` applied around
    /// the outside of it. So the request is written down here and picked up in there. See the
    /// `onChange` beside the scroll geometry.
    @State private var jumpTarget: String?

    /// Searching within this conversation. The store is made when the search opens and let go when
    /// it closes — see `openRoomSearch`. Its results jump through the same `jumpTarget` road a reply
    /// or a global-search hit takes.
    @State private var isSearchingRoom = false
    @State private var roomSearch: RoomSearchStore?

    /// Whether the reader is standing at the newest message, which is what decides if an
    /// arriving message is allowed to move the conversation.
    ///
    /// It used to be allowed unconditionally, and that is a bad way to lose your place: you
    /// scroll up to read something from last week, somebody says "ok" in the room, and you are
    /// thrown back to the bottom. In a busy room it happens again on every message, and there
    /// is no way to read anything old at all.
    ///
    /// It is answered twice, by two signals that cannot both be wrong, and *either* saying yes is
    /// yes. Neither can say yes when the reader is not at the end — one measures a distance, the
    /// other asks whether the end of the conversation is on the screen — so their union is safe,
    /// and their union is what was missing. The scroll geometry alone got this wrong in exactly one
    /// place, and it is the place people actually sit: the composer is a `safeAreaInset`, and
    /// depending on how the scroll view accounts for that inset a list resting against its last
    /// message can report itself a composer's height short of the bottom, forever. That is why the
    /// way-down button would not go away until the list was heaved past its own end, into the
    /// rubber band, where the arithmetic finally went negative.
    ///
    /// Starts true, because a room opens on its newest message — see `hasAnchored`.
    private var isAtNewest: Bool { isNearBottom || endIsOnScreen }

    /// Distance to the end, from the scroll view.
    @State private var isNearBottom = true

    /// The end of the conversation, as a thing that is either on the screen or is not — see the
    /// marker under the last row.
    @State private var endIsOnScreen = true

    /// The room-info screen, built when the header is first pressed and kept afterwards.
    ///
    /// Held rather than made on the spot, because `navigationDestination` evaluates its
    /// destination whenever the view around it redraws — and a fresh `RoomDetailsStore`
    /// each time would re-fetch the member list on every keystroke in the composer behind
    /// it.
    @State private var details: RoomDetailsStore?
    @State private var isShowingDetails = false

    /// Whether the room has already been put down. See `tearDown()` — there are two ways out and
    /// they can both fire.
    @State private var hasTornDown = false

    /// Something the *device* refused — the microphone, an unreadable file. It lives here, with the
    /// alert that shows it, and not in the store: see `RoomProblem`.
    @State private var problem: RoomProblem?

    /// The width the messages have to live in. See `EnvironmentValues.timelineWidth`.
    @State private var timelineWidth: CGFloat = 0

    /// How the conversation is drawn: bubbles on two sides, or one plain column. Chosen once in
    /// settings and read here, which is the only place in the app that acts on it — see
    /// `MessageLayout` and `messageRow(_:in:)`.
    @AppStorage(MessageLayout.storageKey) private var messageLayout: MessageLayout = .default

    /// How tall the conversation is and how far into it the reader has come.
    private struct ScrollMetrics: Equatable {
        let contentHeight: CGFloat
        let offset: CGFloat
    }

    @State private var metrics = ScrollMetrics(contentHeight: 0, offset: 0)

    /// Where the reader was standing when a message arrived at the far end of a conversation they
    /// are not looking at — the one place the bottom anchor has to be overruled, and the only
    /// thing this view moves the scroll view *in points* for. Everything else it does through the
    /// `ScrollViewReader`, which speaks in rows.
    @State private var held: ScrollMetrics?

    @State private var scrollPosition = ScrollPosition()

    /// Whether the conversation is being kept at its end while a message that has just landed
    /// finishes taking its shape.
    ///
    /// One `scrollTo` at the moment the row appears is not enough, and the reason is the one the
    /// opening hold already knows: a row is not its final height when it is inserted. The bubble
    /// is laid out, then the picture in it arrives, then the reply quote above it resolves, and
    /// each of those makes the conversation taller *after* the scroll has already been told
    /// where to go. So the end was missed by a few dozen points, which is enough for
    /// `isAtNewest` to answer no — and then the little round button appears, over the very
    /// message that was just sent.
    ///
    /// So the end is held rather than aimed at, for as long as it takes a message to settle. The
    /// reader touching the conversation ends it at once: see `onScrollPhaseChange`.
    @State private var followsEnd = false
    @State private var followingEnd: Task<Void, Never>?

    /// The message the conversation has just been sent to by pressing a quote, lit until the
    /// reader has had time to see which one it is — and the timer that puts it out. See `light`.
    @State private var highlighted: String?
    @State private var lighting: Task<Void, Never>?

    /// Trustworthy *here*, unlike in the sidebar. `RoomView` fills the split view's detail
    /// column, so the size class it reads is the width of the space it actually draws in —
    /// and how much room the title bar has is precisely the question the header's shape
    /// turns on. See `RoomListView.isSidebar` for the case where this reasoning goes wrong.
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// Whether the app is still the thing the user is looking at.
    ///
    /// Nothing in this app read this, and a recording is precisely the state that cannot survive
    /// not being watched. The camera is the dangerous one: iOS interrupts the capture session when
    /// the app goes away, and the frames that arrive when it comes *back* carry timestamps a minute
    /// later than the ones before them — which `VideoNoteWriter` reads, correctly, as sixty seconds
    /// having elapsed, and it does what it is told to do at sixty seconds. It ends the take and
    /// sends it. A video message the user never finished, sent because they took a phone call.
    @Environment(\.scenePhase) private var scenePhase

    /// The room-info store, made on demand rather than passed in ready — it is a screenful
    /// of requests, and most conversations are read without ever opening it. It comes from
    /// the session, because it needs the `Client` as well as the room: a room's
    /// notification rule lives on the account.
    var makeDetails: () -> RoomDetailsStore?

    /// Leaving a room takes this whole screen away with it, and this screen cannot do
    /// that: the room it is showing is chosen above, in the split view. Same shape as
    /// sign-out in `RoomListView` — the act is reported upwards and performed there.
    var onLeave: () -> Void

    /// Closing the conversation without leaving the room — Escape, on a Mac. Reported upwards for
    /// the same reason `onLeave` is: which room is open is decided in the split view, not here.
    var onClose: () -> Void

    public init(timeline: TimelineStore,
                makeDetails: @escaping () -> RoomDetailsStore?,
                openAt: Binding<String?> = .constant(nil),
                onLeave: @escaping () -> Void,
                onClose: @escaping () -> Void = {}) {
        _timeline = State(initialValue: timeline)
        self.makeDetails = makeDetails
        _openAt = openAt
        self.onLeave = onLeave
        self.onClose = onClose
    }

    /// The message this room is being opened *on*, if it is being opened on one — a search result.
    /// Consumed once and cleared, so that returning to the room by ordinary means goes nowhere.
    @Binding private var openAt: String?

    /// A phone-shaped title bar: an iPhone, or an iPad window squeezed narrow enough to be
    /// one. Never the Mac, which has no size class worth asking.
    private var isCompact: Bool {
        #if os(macOS)
        false
        #else
        horizontalSizeClass == .compact
        #endif
    }

    /// There is a conversation on screen to be put in its place. Both halves matter: a room
    /// that has loaded and is genuinely empty has no newest message to open on, and a room
    /// with rows that has not finished its first fetch has one that is about to change.
    private var isReady: Bool {
        timeline.hasLoaded && !timeline.rows.isEmpty
    }

    /// The room-info screen, built on the first press and kept, so going back and forth
    /// does not reload the member list each time.
    private func openDetails() {
        if details == nil { details = makeDetails() }
        isShowingDetails = true
    }

    private func openRoomSearch() {
        if roomSearch == nil { roomSearch = timeline.makeSearch() }
        isSearchingRoom = true
    }

    /// The room's media, handed to every picture in it — see `RoomMediaSource`.
    ///
    /// Made once, on appearing, and held: a source rebuilt on each pass of this body would be a new
    /// value in the environment every time anything in the conversation changed, and would
    /// invalidate every row in it.
    @State private var mediaSource: RoomMediaSource?

    public var body: some View {
        ScrollViewReader { scroll in
            ScrollView {
                LazyVStack(spacing: 0) {
                    loadEarlier

                    ForEach(placedRows) { placed in
                        view(for: placed.row,
                             followsEvent: placed.followsEvent,
                             opensDay: placed.opensDay,
                             arrives: placed.arrives,
                             in: scroll)
                            .id(placed.id)
                    }

                    // Someone writing, shown as an unfinished incoming message at the foot of the
                    // conversation — the header says who, this is the animation of it. It comes up
                    // from below and fades, exactly as a message does (`AnyTransition.arrival`),
                    // and goes back down the same way when they stop.
                    //
                    // The `VStack` is load-bearing and must not go back to being a `Group`. A
                    // `Group` is not a container: it hands every modifier to each of its members,
                    // so the `.animation` below landed on `TypingBubble` itself rather than around
                    // the `if` that inserts it — no animated transaction, no transition, and the
                    // bubble popped in and out while the modifier that was supposed to stop it sat
                    // right there looking correct.
                    //
                    // This is the one implicit animation scope in the conversation, and it is
                    // allowed because of how little it wraps: a single bubble whose only other
                    // animatable state, the pulse of the dots, carries an `.animation` of its own
                    // further in and therefore wins. Nothing else can be caught by it.
                    //
                    // The animation is explicit now, in `setTyping`, rather than a scope here —
                    // see `showsTyping` for why the bubble no longer follows the store directly.
                    VStack(spacing: 0) {
                        if showsTyping {
                            TypingBubble()
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, Theme.Spacing.withinRun)
                                .transition(.asymmetric(insertion: .arrival,
                                                        removal: .opacity.animation(.easeOut(duration: Theme.Timing.chrome / 2))))
                        }
                    }

                    endMarker
                }
                // **No `.animation` here, and none may be added.** This modifier wraps the
                // whole conversation, and an implicit scope animates *every* animatable value in
                // what it wraps whenever the one value it watches changes — so a scope here is a
                // standing offer to animate a delivery tick, a reaction, an edit or a redaction
                // because something else happened in the same pass. That is the bug that came
                // back three times under three different values: the tail of the list, then the
                // send queue, then the end of the conversation. Each looked narrow and each of
                // them animated the wrong thing, because the thing being watched was never the
                // thing being animated.
                //
                // A message arriving now animates *itself*, from inside the row, and asks the
                // list for nothing. See `MessageRow.arrivesAnimated`.
                //
                // The typing bubble's own animation used to be here too, watching
                // `timeline.typing`, which is a thing that changes constantly in a busy
                // conversation and animated the entire column every time it did. It rides with
                // the bubble now.
                .padding(.horizontal, Theme.Spacing.normal)
                // The composer floats over the timeline on glass, so the last message
                // must be able to scroll clear of it — but only just. The composer already
                // carries its own padding, and a generous gap on top of that reads as the
                // conversation having ended some way above the bar you answer it in.
                .padding(.bottom, Theme.Spacing.close)
            }
            // Drag the conversation and the keyboard goes down with your finger.
            //
            // `.interactively` rather than `.immediately` because the keyboard should follow the
            // hand rather than vanish at the first pixel of movement: pulling down takes it down
            // with you, and changing your mind halfway puts it back. Reaching for something further
            // up the conversation is the one gesture that plainly means "I have stopped typing for
            // a moment", and until now it left half the screen covered by a keyboard nobody was
            // using.
            .scrollDismissesKeyboard(.interactively)
            .defaultScrollAnchor(.bottom)
            // What keeps the conversation still while history lands on top of it.
            //
            // A scroll view holds its offset from the *top* of the content, so anything added
            // above the reader pushes what they are reading down the screen — and a page of
            // history is nothing but twenty-five things added above the reader. Anchoring size
            // changes to the bottom inverts that: the end of the conversation is what stays put,
            // and the content grows away from it, upwards, out of sight.
            //
            // This is what an anchor kept by hand could never do, and it is worth knowing why.
            // A page does not arrive as one change. The SDK hands its diffs over in batches, each
            // batch crosses to the main actor as its own `Task`, and each publishes `rows` again —
            // so the content grows in several steps across several frames. Then the older events
            // *decrypt*, and their rows change height where they stand, above the reader, after
            // they have already been laid out. Then the photos in them arrive and change height
            // again. There is no single moment to measure and put back; there are a dozen, and the
            // only cure is to make the scroll view hold the end it is not being changed at.
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
            .scrollPosition($scrollPosition)
            // The spinner floats over the top of the conversation rather than standing at the
            // head of it.
            //
            // It used to be the first row of the stack, and a row it cannot be: it appears the
            // moment a page is asked for and leaves the moment the page lands, so it grew and
            // shrank the content *above* the reader twice per page — two shoves in opposite
            // directions, on top of the shove the page itself gave. Nothing it says is worth a
            // line of the conversation moving.
            //
            // Which is *not* a reason to leave it out, and it was left out: a bare `ProgressView`
            // laid over the top of a conversation, at the very edge of the scroll view, under a
            // glass toolbar. It was drawn and nobody could see it, which is the same as not
            // fetching anything at all as far as the reader is concerned — they pull up, the room
            // sits there, and nothing tells them the rest of the conversation is on its way. So it
            // is a disc of glass now, clear of the toolbar, on the navigation layer where a
            // floating control belongs.
            .overlay(alignment: .top) {
                if Self.showsHistorySpinner, isFetchingHistory {
                    ProgressView()
                        .controlSize(.small)
                        .padding(Theme.Spacing.close)
                        .navigationGlass(in: .circle)
                        .padding(.top, Theme.Spacing.normal)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            // The spinner is shown for a *little longer* than the fetch it stands for, and this is
            // not decoration.
            //
            // History almost always comes out of the SDK's own store on this device, not off the
            // network: `paginateBackwards` reads the encrypted event cache and returns in
            // milliseconds. So `isPaginating` went up and came down inside a single frame, the
            // spinner was drawn for none of it, and the reader pulling at the top of a room saw
            // absolutely nothing happen — which is exactly what they would see if the room had no
            // more history to give. Telling those two apart is the spinner's whole job.
            //
            // Held for a beat, then. It is not a lie: the fetch did happen, and the disc is
            // reporting it slightly slower than it occurred so that a person can read it.
            .onChange(of: timeline.isPaginating) { _, isPaginating in
                spinnerRest?.cancel()

                guard !isPaginating else {
                    withAnimation(.smooth) { isFetchingHistory = true }
                    return
                }

                spinnerRest = Task {
                    try? await Task.sleep(for: Self.spinnerRest)
                    guard !Task.isCancelled else { return }
                    withAnimation(.smooth) { isFetchingHistory = false }
                }
            }
            // How much room the conversation has. Measured here, on the container, and never
            // inside a row — see `EnvironmentValues.timelineWidth` for the lock-up that
            // taught us the difference. The horizontal padding is taken off because it is
            // outside the messages, not available to them.
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width - Theme.Spacing.normal * 2
            } action: { width in
                timelineWidth = width
            }
            .environment(\.timelineWidth, timelineWidth)
            // The room's pictures, for the viewer a tapped photograph opens — so that it can be
            // swiped through the conversation's media the way the media tab's can. Built once, and
            // not on every pass of this body: see `RoomMediaSource`.
            .environment(\.roomMedia, mediaSource)
            .onAppear {
                guard mediaSource == nil else { return }
                mediaSource = RoomMediaSource { [timeline] in
                    MediaItem.items(from: timeline.rows.compactMap(\.message))
                }
            }
            // The messages fade out under the toolbar rather than being cut off by a line.
            //
            // Where the content meets the toolbar, macOS resolves the automatic scroll-edge
            // effect to `.hard` — a hairline ruled across the top of the conversation — while
            // iOS resolves it to `.soft`. That is the whole reason the Mac wore a grey stripe
            // above its first message and the iPhone did not. A chat has nothing to separate
            // there: the toolbar is already a glass surface, and the rule only fenced the top
            // message off from the name of the person who sent it.
            .scrollEdgeEffectStyle(.soft, for: .top)
            // Reaching the top is the request for older messages — the gesture people
            // already make, rather than a spinner they have to notice. `loadMore` ignores
            // a call while it is already paginating and once the room has no more history,
            // so firing this eagerly costs nothing.
            //
            // Not before the conversation has been anchored, though, and that guard is the
            // whole reason a room used to open on its oldest message. A timeline starts
            // empty and fills from the top, so until the newest message has been scrolled
            // to, the scroll view is sitting at offset zero — which *is* "near the top", so
            // this asked for more history, which arrived above and left it at offset zero
            // again, and again. The room wound itself back to its first day while the reader
            // watched. History is a request the reader makes by scrolling; they cannot make
            // it before they have been shown where the conversation actually is.
            //
            // Where the conversation is standing: what asks for history, and the two moments the
            // scroll view has to be put somewhere other than where it would leave itself.
            //
            // The request for history used to hang off its own observer, watching a *Bool* —
            // "is the reader within reach of the top" — and `onScrollGeometryChange` only calls
            // its action when the value it watches **changes**. That is the whole of why loading
            // older messages worked in fits and starts. A page of twenty-five events can be two
            // rows tall, so the content grew by less than the reach and the reader was still
            // within it: the Bool was true before the page and true after it, never changed, and
            // never fired again. The room sat at its top with more history to give and nothing
            // asking for it, and the only way to shake another page out of it was to scroll *down*
            // far enough to make the answer false and come back up.
            //
            // Watching the geometry itself has no such gap: every scroll and every change of
            // content is a call, and being near the top is simply asked afresh each time.
            // Firing it eagerly costs nothing — `loadMore` ignores a call while a page is already
            // in flight, and does nothing once the room has no more history.
            .onScrollGeometryChange(for: ScrollMetrics.self) { geometry in
                ScrollMetrics(contentHeight: geometry.contentSize.height,
                              offset: geometry.contentOffset.y)
            } action: { _, metrics in
                self.metrics = metrics

                if metrics.offset < Theme.Size.paginationReach, hasAnchored {
                    Task { await timeline.loadMore() }
                }

                // A room opens on its newest message, and *stays* there until the reader takes
                // hold of it. One `scrollTo` at the moment the first page lands is not enough and
                // this is why: opening a room is not one change of size, it is a long series of
                // them. The store keeps fetching until it has a screenful, each batch of diffs
                // publishes its own rows, the events then decrypt and their rows change height,
                // and the photos in them arrive and change height again. Scrolling to the bottom
                // once, in the middle of that, lands on a conversation that is still growing —
                // which is precisely the room that opened a few messages short of the end. So the
                // end is *held* until the reader disagrees by scrolling.
                //
                // Deferred: calling `scrollTo` synchronously inside `onScrollGeometryChange`
                // changes the scroll position, which fires the callback again — a re-entrant
                // loop that produced "tried to update multiple times per frame" and hung the
                // app. A `Task` breaks the cycle: the current callback finishes, and the scroll
                // lands on the next pass through the run loop.
                if isOpening {
                    Task { scrollPosition.scrollTo(edge: .bottom) }
                    return
                }

                // The same hold, for the moments after a message lands rather than the moments
                // after the room opens. See `followsEnd`. Deferred for the same reason as above:
                // scrolling from inside this callback calls it again.
                if followsEnd {
                    Task { scrollPosition.scrollTo(edge: .bottom) }
                    return
                }

                guard let place = held, metrics.contentHeight > place.contentHeight else { return }
                held = nil
                scrollPosition.scrollTo(y: place.offset)
            }
            // Moving the conversation is what says the reader wants it left where they put it.
            // An arriving message is not the reader, and neither is a photo finishing its
            // download — but *any* way of scrolling is.
            //
            // It used to listen for `.interacting` alone, which is a finger on the glass and
            // nothing else. A trackpad, a mouse wheel and a scroll bar do not produce it, so on
            // those the room went on holding its own end for as long as it was open: history could
            // not be asked for, because the hold outranked the request, and the only way to break
            // out was to *drag* the list hard enough to reach the rubber band. That is the bug
            // reported as "scrolling to the top only loads more if you pull".
            //
            // So every phase counts except the two that are not the reader: `.idle`, and the
            // `.animating` of a scroll this view asked for itself — including the hold's own.
            .onScrollPhaseChange { _, phase in
                guard phase != .idle, phase != .animating else { return }
                isOpening = false
                // Moving the conversation yourself outranks the room's wish to stay at the end —
                // the same rule the opening hold follows, and for the same reason. See
                // `followsEnd`.
                followsEnd = false
                followingEnd?.cancel()
            }
            // Opening a room puts it on its newest message, once — the moment the first
            // fetch has come back with something to show. `initial: true` covers a room
            // whose store was already open and full before this view was ever built.
            // Where the conversation ends, remembered for the next pass — which is the whole of
            // what tells an arrival from a page of history. See `newestRowID`.
            //
            // It runs *after* the rows have been drawn, and that is the right way round: the pass
            // that first shows a new message still sees the old end, works out that the message
            // comes after it, and animates it. This only writes down where the end is now.
            //
            // `initial: true` so that a room whose store was already full before this view was
            // built records its end without a thing moving.
            .onChange(of: timeline.rows.last?.id, initial: true) { _, last in
                newestRowID = last
            }
            // The typing bubble — see `showsTyping`.
            .onChange(of: timeline.typing.isEmpty, initial: true) { _, isEmpty in
                setTyping(!isEmpty)
            }
            .onChange(of: timeline.rows.last?.id) { _, _ in
                guard showsTyping, timeline.rows.last?.message?.isOwn == false else { return }
                typingHide?.cancel()
                var quietly = Transaction()
                quietly.disablesAnimations = true
                withTransaction(quietly) { showsTyping = false }
                // Somebody else may still be writing; if so, they get the bubble back.
                if !timeline.typing.isEmpty { setTyping(true) }
            }
            // The store has a conversation: show it. `initial: true` for a room whose store was
            // already open and full before this view existed — there is nothing to wait for, and
            // it must not blink.
            .onChange(of: timeline.hasLoaded, initial: true) { _, loaded in
                if loaded { isRevealed = true }
            }
            // …and a floor under it, because "when the store is done" is a promise about a
            // network. A conversation half-fetched is worth more than an empty screen that goes
            // on being empty, so past this point the room is shown with whatever it has.
            .task {
                try? await Task.sleep(for: Theme.Timing.roomWaitsToBeSeen)
                isRevealed = true
            }
            .onChange(of: isReady, initial: true) { _, ready in
                guard ready, !hasAnchored, let last = timeline.rows.last?.id else { return }
                hasAnchored = true
                // Not animated: this is where the room *opens*, not somewhere it travels to. The
                // hold above keeps it there while the conversation finishes arriving; this is
                // only the first of those moves, made as soon as there is a row to make it to.
                scroll.scrollTo(last, anchor: .bottom)

                // The room may now move — but not this instant. The batches still in flight, the
                // decryptions and the pictures all land in the moments after the first page is
                // ready, and each of them would otherwise be animated as though somebody had just
                // said something. A beat of stillness costs nothing: nothing the reader did is
                // waiting on it, and the only thing it delays is the arrival of a message that
                // has not been sent yet. See `hasSettled`.
                Task {
                    try? await Task.sleep(for: Theme.Timing.timelineSettles)
                    hasSettled = true
                }

                // …and if it was opened *on* a message — a search result — it goes there next. The
                // anchor still happens first, and deliberately: a conversation has to have
                // somewhere to be before it can travel anywhere, and jumping out of a scroll view
                // that has not yet settled at the bottom lands nowhere in particular.
                if let openAt {
                    jumpTarget = openAt
                    self.openAt = nil
                }
            }
            // A search hit in a room that is *already* open. On iPhone this never arises: going back
            // clears the selection, so tapping a result rebuilds the view and the first-open path
            // above carries the target. But on iPad and Mac the room stays put in the detail column
            // beside the list — only `openAt` changes, the view is not rebuilt, `isReady` does not
            // move, and the handler above never runs again. Without this, tapping a result in the
            // conversation you are already looking at does nothing at all. So a target that lands
            // after the room has anchored is taken to the same `jumpTarget` machinery.
            .onChange(of: openAt) { _, target in
                guard hasAnchored, let target else { return }
                jumpTarget = target
                openAt = nil
            }
            // Somebody asked to be taken to a message — see `jumpTarget`.
            //
            // A pinned message is very often *not loaded*: it was pinned because it matters, and
            // things that matter get pinned early. `scrollTo` on an identity the list does not hold
            // does nothing whatsoever — silently — which is why pressing the pinned strip appeared
            // to open the list instead of going anywhere. So the history is pulled in until the
            // message is actually there to be scrolled to.
            //
            // Bounded, and giving up quietly. A message pinned two years ago is not worth
            // paginating a room back to its creation for, and a jump that cannot be made is better
            // as a jump that does not happen than as a room that spends a minute rewinding itself.
            .onChange(of: jumpTarget) { _, target in
                guard let target else { return }
                jumpTarget = nil
                // Being sent to a message is a place to be, so the room stops holding the end of
                // the conversation — otherwise the hold would haul it straight back.
                isOpening = false

                Task {
                    var pages = 0
                    while !timeline.rows.contains(where: { $0.id == target }),
                          timeline.canLoadMore,
                          pages < Self.jumpPages {
                        await timeline.loadMore()
                        pages += 1
                    }

                    guard timeline.rows.contains(where: { $0.id == target }) else { return }

                    withAnimation(.smooth) { scroll.scrollTo(target, anchor: .center) }
                    light(target)
                }
            }
            // How near the end the reader is, measured the same way the pagination trigger above
            // is, from the other end of the scroll view. Half of the answer — the other half is the
            // marker under the last row, and `isAtNewest` says why there are two.
            .onScrollGeometryChange(for: Bool.self) { geometry in
                let distanceFromBottom = geometry.contentSize.height
                    + geometry.contentInsets.bottom
                    - geometry.contentOffset.y
                    - geometry.containerSize.height
                return distanceFromBottom < Theme.Size.newestReach
            } action: { _, isNear in
                isNearBottom = isNear
            }
            // Arriving at the end is having seen it. The pill has nothing left to offer — and the
            // sender has something to be told.
            //
            // The receipt is the half that was missing. It went out on opening the room and again
            // whenever a message arrived *while* the reader stood at the end, which leaves out the
            // most ordinary way of reading a chat there is: scroll up through what came in, scroll
            // back down, read every word of it, and the server never hears. The badge sat there,
            // and on the other side of the conversation the messages kept one tick.
            .onChange(of: isAtNewest) { _, atNewest in
                guard atNewest else { return }
                Task { await timeline.markAsRead() }

                guard hasUnseenBelow else { return }
                withAnimation(.smooth) { hasUnseenBelow = false }
            }
            // And afterwards, a message arriving brings the conversation with it — but *only*
            // if the reader is standing at the end of it. Somebody reading last week's messages
            // is not asking to be taken to today's, and taking them there anyway is how a busy
            // room becomes impossible to read backwards at all.
            //
            // Your own message is the exception, and it is not really an exception: sending one
            // is a request to be where it lands. The composer is at the bottom, so you are
            // answering the newest message by definition.
            .onChange(of: timeline.rows.last?.id) { _, last in
                guard hasAnchored, let last else { return }

                guard isAtNewest || timeline.rows.last?.message?.isOwn == true else {
                    // Not going anywhere — but something *did* arrive, and the reader is not
                    // looking at it. That is what the pill is for: the room no longer drags them
                    // to the bottom, so it has to offer.
                    withAnimation(.smooth) { hasUnseenBelow = true }

                    // And the anchor has to be overruled, this once. It holds the *bottom* of the
                    // conversation still, which is exactly right while history piles up above the
                    // reader and exactly wrong when a message lands below them: holding the bottom
                    // still would drag them down to meet it, which is the very thing the pill
                    // exists to avoid. So where they are standing now is noted, and put back the
                    // moment the message has made the conversation taller. Read *before* the
                    // arriving row is laid out — `onChange` runs on the change, not on the frame
                    // it produces — so this is the conversation as it was without it.
                    held = metrics
                    return
                }

                // To the end of the *conversation*, not to the last message — and that
                // distinction is the whole of the jump-to-bottom button appearing over a message
                // that had just been sent.
                //
                // `scrollTo(last, anchor: .bottom)` puts the bottom of the last row against the
                // bottom of the viewport, and there are things below the last row: the space the
                // typing bubble takes when somebody is writing, the padding that lifts the
                // conversation off the composer, and the end marker itself. All of it stayed
                // below the fold — including the marker, which is one of the two things that
                // answer "is the reader at the end". So the room scrolled as far as it had been
                // asked to, reported itself short of the end, and offered a button to go to the
                // end it was already at, on top of the message it was showing.
                //
                // Not animated, and that is the other half. Two things were moving at once and
                // not together: the row rising on a spring, and the scroll gliding on `.smooth`.
                // Two curves of different lengths over the same few dozen points read as one
                // thing stuttering — because from the reader's side it *is* one thing, the
                // message they just sent, animated twice.
                followEnd()
            }
            // Laid out from the first row, shown only when there is a whole conversation to
            // show — see `isRevealed`. Opacity and not an `if`: the scroll view has to exist and
            // do its work while it is hidden, because what it is doing is anchoring itself to the
            // bottom of a conversation that is still arriving. Built only at the end, it would
            // have to do all of that in front of the reader, which is the thing being cured.
            .opacity(isRevealed ? 1 : 0)
            // Over the timeline but *under* the composer, which is a safe-area inset added
            // further down: a placeholder that covered the box you type into would be
            // telling you to say something and hiding the way to say it.
            .overlay { placeholder }
            // The way back down. Inside the `ScrollViewReader`, because that is the only place the
            // proxy exists — and at the bottom of the conversation rather than floating in the
            // middle of it, because that is the direction it takes you.
            .overlay(alignment: .bottom) {
                Group {
                    if hasUnseenBelow {
                        jumpToNewest()
                            .padding(.bottom, Theme.Spacing.close)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(.smooth(duration: Theme.Timing.chrome), value: hasUnseenBelow)
            }
            // And the plain way down, for when nothing has been said and you are simply a long
            // way up. This did not exist, and its absence is only invisible on a short
            // conversation: reading back through a year of a room left the only route to the
            // bottom being to *scroll* there, past the whole year, or to leave the room and come
            // back in. The pill above cannot serve — it is about a message that arrived, and on a
            // quiet room it never appears.
            //
            // Trailing, and up in the corner rather than in the middle: it is a control, not an
            // announcement, and the middle of the screen belongs to the pill on the rare occasions
            // there is one. When both are on screen they do not collide.
            .overlay(alignment: .bottomTrailing) {
                Group {
                    if !isAtNewest {
                        scrollToBottom()
                            .padding(.trailing, Theme.Spacing.normal)
                            .padding(.bottom, Theme.Spacing.close)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                // On the button, not on the room. This scope used to sit out here on the whole
                // `ScrollViewReader` — the scroll view, every row in it, and the reveal that
                // shows the conversation — watching a value that flips whenever the reader
                // reaches or leaves the end of the chat. A room filling itself in reaches the end
                // while it fills, so opening a chat animated the entire conversation, including
                // the moment it became visible. That is the "strange animation on opening", and
                // it came from a modifier about a little round button in the corner.
                .animation(.smooth(duration: Theme.Timing.chrome), value: isAtNewest)
            }
        }
        .safeAreaInset(edge: .bottom) {
            Group {
                if timeline.canPost {
                    composer
                } else {
                    readOnlyBanner
                }
            }
            .animation(.smooth, value: timeline.canPost)
        }
        // Over everything, composer included: while the camera is up, the room is the thing
        // being answered rather than the thing being used.
        //
        // The fade is a `withAnimation` at the two places the flag moves, and *not* an
        // `.animation(value:)` here: this is the outermost view in the room, and an implicit
        // animation on it would animate every animatable value in the whole subtree — the
        // timeline, the rows, the composer — each time the camera came up.
        .overlay { videoNoteOverlay }
        // What the conversation is standing on: nothing, a gradient, or a picture of the user's
        // own, taken down as far as they asked — see `Wallpaper`. Applied here, on the whole room
        // rather than on the scroll view inside it, so that the wallpaper runs under the composer
        // and the pinned strip instead of stopping at the edge of the messages.
        .chatWallpaper()
        // The strip at the top of the room, above the conversation and below the toolbar.
        // Present only when there is something pinned — a room with nothing pinned should not
        // give up a row of its screen to say so.
        .safeAreaInset(edge: .top) {
            Group {
                if !timeline.pinnedEventIDs.isEmpty, let pinned {
                    PinnedStrip(pinned: pinned,
                                onGoTo: { message in jumpTarget = message.id },
                                onOpenList: { isShowingPinned = true })
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            // Scoped to the strip itself, exactly as the composer's is below, and not to the
            // room. It used to hang off the outermost view — which is what the note on the
            // video overlay above warns against: an implicit animation there animates *every*
            // animatable value in the subtree, the whole conversation included, and a room's
            // pinned list is first reported while that conversation is still filling itself in.
            // Opening a pinned room therefore set every message in it sliding.
            .animation(.smooth, value: timeline.pinnedEventIDs)
        }
        // Above the pinned strip, because it is about the whole app rather than about this room —
        // and because somebody reading a conversation should not have to go back to the list to find
        // out why nothing new is arriving in it. See `OfflineBanner`.
        .offlineBanner()
        // Opened the first time the room reports anything pinned, and kept afterwards. A room
        // with nothing pinned never opens a second timeline at all.
        .onChange(of: timeline.pinnedEventIDs.isEmpty, initial: true) { _, isEmpty in
            guard !isEmpty, pinned == nil else { return }
            let store = timeline.pinned()
            pinned = store
            Task { await store.start() }
        }
        // The name still goes on the navigation item, even though the header draws it: it
        // is the window's title on the Mac, and it is what the back button that returns
        // here is labelled with.
        .navigationTitle(timeline.roomName)
        // …but on a wide screen the system must not *draw* it. It was drawing it anyway,
        // beside our header rather than instead of it, and the Mac and the iPad both showed
        // the room's name twice.
        //
        // Only on a wide screen, though, hence the optional. A phone's title bar has one
        // slot in the middle and the principal item *is* the title there — remove the title
        // on a phone and `RoomTitle` goes with it, leaving a bar with a back button, an
        // avatar and nothing in between. Confirmed on the way in, not guessed.
        .toolbar(removing: isCompact ? nil : .title)
        #if !os(macOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            if isCompact {
                // iPhone. The name goes where a phone puts a title — the middle — and the
                // picture goes to the trailing edge, near the thumb. Two controls, one
                // destination: both open the room.
                ToolbarItem(placement: .principal) {
                    RoomTitle(name: timeline.roomName,
                              privacy: timeline.privacy,
                              subtitle: headerSubtitle,
                              onOpenDetails: openDetails)
                }
                // Out of the toolbar's shared glass. A title is the heading of the screen,
                // not a control hovering over it, and a capsule of glass around these words
                // says the opposite.
                .sharedBackgroundVisibility(.hidden)

                // Out of the shared background, and — unlike the title above — *not* because
                // it should be bare. It carries a glass circle of its own instead, cut to the
                // picture: the toolbar's shared background comes with the toolbar's margins,
                // and a round picture inside them wears a capsule with a sliver of glass down
                // either side. See `RoomAvatarButton`.
                ToolbarItem(placement: .primaryAction) {
                    RoomAvatarButton(name: timeline.roomName,
                                     avatarURL: timeline.roomAvatarURL,
                                     avatarSeed: timeline.roomAvatarSeed,
                                     faces: timeline.roomFaces,
                                     onOpenDetails: openDetails)
                }
                .sharedBackgroundVisibility(.hidden)
            } else {
                // Mac and iPad. Room enough for the picture and the name together, at the
                // leading edge — lined up with the conversation below rather than floating
                // in the centre of a bar that is mostly empty.
                ToolbarItem(placement: .navigation) {
                    RoomHeader(name: timeline.roomName,
                               avatarURL: timeline.roomAvatarURL,
                               avatarSeed: timeline.roomAvatarSeed,
                               faces: timeline.roomFaces,
                               privacy: timeline.privacy,
                               subtitle: headerSubtitle,
                               onOpenDetails: openDetails)
                }
                .sharedBackgroundVisibility(.hidden)
            }
        }
        .sheet(isPresented: $isSearchingRoom) {
            if let roomSearch {
                RoomSearchView(store: roomSearch) { eventID in
                    isSearchingRoom = false
                    // The same road a reply takes: paginate back until the message is loaded, then
                    // scroll to it and light it.
                    jumpTarget = eventID
                }
            }
        }
        .navigationDestination(isPresented: $isShowingDetails) {
            if let details {
                // Leaving the room from the info screen is still leaving the room — and it was the
                // one way out that tore nothing down. `onDisappear` below declines to clean up when
                // the room is merely covered by a pushed screen, and at the moment "Leave" takes
                // effect the info screen *is* still pushed, so the guard held and the whole teardown
                // was skipped: the draft unsaved, the listeners running, "typing…" left standing in
                // a room the user had just walked out of, and a locked voice recording still
                // listening. So it is done here, explicitly, before the room goes.
                RoomInfoView(details: details, timeline: timeline, onLeave: {
                    tearDown()
                    onLeave()
                }, onSearch: {
                    isShowingDetails = false
                    openRoomSearch()
                })
            }
        }
        .navigationDestination(isPresented: $isShowingPinned) {
            if let pinned {
                PinnedMessagesView(pinned: pinned, isOneToOne: timeline.isOneToOne)
            }
        }
        .photosPicker(isPresented: $isChoosingPhoto,
                      selection: $pickedItem,
                      matching: .any(of: [.images, .videos]))
        .onChange(of: pickedItem) { _, item in
            guard let item else { return }
            Task { await sendPicked(item) }
            // Cleared so that picking the same photo twice in a row is two attachments and
            // not one: `onChange` fires on a *change*, and the second pick is not one.
            pickedItem = nil
        }
        .fileImporter(isPresented: $isChoosingFile, allowedContentTypes: [.item]) { result in
            guard case let .success(url) = result else { return }
            Task { await sendPickedFile(url) }
        }
        .sheet(isPresented: $isChoosingLocation) {
            LocationPicker { location in
                await timeline.send(location: location, replyingTo: replyID)
                cancelContext()
            }
        }
        // Writing. `typed()` is cheap to call on every keystroke on purpose — it tells the server
        // once and then only pushes back the moment it takes it back — so this can be exactly what
        // it looks like: the user typed something.
        //
        // An empty box is not writing. Deleting the last character of a draft is the clearest
        // possible statement that nothing is being written, and `send` empties it too, so this also
        // covers the moment the message actually goes.
        .onChange(of: draft) { _, text in
            if text.isEmpty {
                Task { await timeline.stoppedTyping() }
            } else {
                timeline.typed()
            }
        }
        .task {
            // Whatever was half-written here last time. Restored *before* the room opens, because
            // it costs nothing and it means the composer is never briefly empty in front of
            // somebody who left a sentence in it.
            //
            // Only when the box is genuinely empty: coming back from the room-info screen re-runs
            // this task, and overwriting a draft the user is in the middle of typing with the one
            // they saved a minute ago would be the app taking words out of their mouth.
            if draft.isEmpty, let saved = await timeline.draft() {
                draft = saved
            }

            try? await timeline.start()
            await timeline.markAsRead()
        }
        // And again whenever something arrives while you are looking at it.
        //
        // Marking once, on open, is enough on a phone — a room you are not in is a room you have
        // left, and you will open it again. It is wrong everywhere else: on an iPad or a Mac the
        // room stays open beside the list, so three messages could land while you read them and
        // the sidebar would go on saying "3" for as long as you sat there, while the sender was
        // never told you had read a word of it.
        //
        // Only when you are actually at the newest message, for the same reason the conversation
        // only follows you there: someone reading last week's messages has not read today's.
        .onChange(of: timeline.rows.last?.id) { _, _ in
            guard isAtNewest else { return }
            Task { await timeline.markAsRead() }
        }
        #if os(macOS)
        // Escape closes the conversation, the way it closes anything else on a Mac. A key
        // equivalent rather than `onExitCommand`, because the latter only reaches a view that
        // holds focus — and the focus is in the composer, which keeps Escape for itself.
        .background {
            Button("", action: escape)
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .accessibilityHidden(true)
        }
        #endif
        // Put the app away mid-recording, and the recording does not survive it — the question is
        // only whether the app admits that.
        //
        // The camera is thrown away outright, and that is the safe direction: iOS interrupts the
        // capture session, and the frames arriving when the app comes back are stamped a minute
        // later than the ones before them. `VideoNoteWriter` reads that, quite correctly, as sixty
        // seconds having passed — and does what it is told to do at sixty seconds, which is end the
        // take and send it. A video message of somebody's face, finished and sent while they were
        // taking a phone call. A clip nobody chose to send is worse than a clip nobody sent.
        //
        // The microphone is not thrown away, and the difference is not an inconsistency. iOS has
        // already stopped it — the recorder notices within the tick and settles into `.stopped` —
        // so what is on the disk is exactly the words the user spoke before they were interrupted,
        // ending where the interruption did. That is a message they may well still want; the strip
        // stays up, with a clock that has stopped, and they can send it or throw it away.
        .onChange(of: scenePhase) { _, phase in
            guard phase != .active, isRecordingVideoNote else { return }
            cancelVideoNote()
        }
        // If the room stops allowing posts while the microphone or camera is running, the
        // composer is replaced by a banner — but the recorders live on this screen, not on the
        // composer, so they keep running unless they are cancelled here.
        .onChange(of: timeline.canPost) { _, canPost in
            guard !canPost else { return }
            cancelVideoNote()
            cancelVoice()
        }
        // The camera goes with the room, and it has to be said here rather than left to the
        // overlay: the overlay used to be a sheet, and a sheet took its own `onDisappear` with
        // it. Nothing else turns the capture session off — leave the room mid-recording and the
        // lens, the microphone and a ten-a-second ticker all carry on behind a screen that is no
        // longer there.
        //
        // And the microphone alone, for exactly the same reason. A voice message has no overlay
        // and never had one, so it never had an `onDisappear` to lose — which made it easy to
        // miss when the camera got one. `VoiceRecorder` holds an audio session and a ticker of
        // its own and has no `deinit` to fall back on: walk out of a room mid-sentence and it
        // keeps listening.
        // A screen *pushed over* the room disappears it too, and that is not leaving.
        //
        // `RoomInfoView` and `PinnedMessagesView` go onto the same `NavigationStack` as the room,
        // and SwiftUI fires `onDisappear` on the view underneath when a destination covers it. So
        // opening the room info stopped the timeline, cancelled the listeners, and — worse — threw
        // away a *locked, hands-free* voice recording that was still running. Coming back, the room
        // was no longer receiving anything.
        //
        // The store recovers from that now (`TimelineStore.stop()` is a pause and `start()` picks
        // it up again), but recovering from it is not a reason to do it: re-opening the timeline
        // and paginating the history back is a lot of work to do because somebody glanced at who
        // is in the room. The flags are the honest signal — we know when we are pushing, because
        // we are the ones who pushed.
        .onDisappear {
            guard !isShowingDetails, !isShowingPinned else { return }
            tearDown()
        }
        // Two alerts, because there are two kinds of bad news and they come from different places.
        // The room refusing something is the store's (`TimelineActionFailure`); the device refusing
        // something is this screen's (`RoomProblem`) — see that type for why the second one no
        // longer gets written into the first. Both go through the shared modifier now: this used to
        // be seven lines of hand-rolled `.alert` doing, slightly differently, what three other
        // screens already had a modifier for.
        .failureAlert($timeline.failure)
        .failureAlert($problem)
    }

    /// Keeps the conversation at its end while a message that has just landed takes its shape.
    ///
    /// A loop, and not one `scrollTo` — see `followsEnd` for why once is not enough. The first
    /// attempt at this hung off the scroll-geometry callback, which sounds tighter and is not: a
    /// row is inserted, the geometry changes, the callback runs, and only *then* does the change
    /// handler that sets the flag get its turn. By the time anything was being held, the
    /// geometry had finished moving and the callback never came again. Asking for the end on a
    /// clock of its own does not depend on the order two handlers happen to run in.
    ///
    /// Putting a scroll view that is already at its end back at its end costs nothing and is
    /// invisible, so the loop is free to be dumb. The reader touching the conversation cancels
    /// it — see `onScrollPhaseChange`.
    /// Puts the typing bubble up at once, or takes it down after `typingGrace` — see
    /// `showsTyping`.
    private func setTyping(_ isTyping: Bool) {
        typingHide?.cancel()
        if isTyping {
            guard !showsTyping else { return }
            withAnimation(Theme.Timing.arrival) { showsTyping = true }
        } else {
            guard showsTyping else { return }
            typingHide = Task {
                try? await Task.sleep(for: Self.typingGrace)
                guard !Task.isCancelled else { return }
                withAnimation(Theme.Timing.arrival) { showsTyping = false }
            }
        }
    }

    /// Escape, on a Mac: the innermost thing that is open closes first. A message menu, then an
    /// answer or an edit being written, and only then the conversation itself.
    private func escape() {
        if let messageMenu, messageMenu.presentation != nil {
            messageMenu.dismiss()
        } else if composerContext != nil {
            withAnimation(.smooth(duration: Theme.Timing.chrome)) { composerContext = nil }
        } else {
            onClose()
        }
    }

    private func followEnd() {
        followingEnd?.cancel()
        followsEnd = true

        followingEnd = Task {
            let deadline = ContinuousClock.now + Theme.Timing.endIsHeld
            while !Task.isCancelled, ContinuousClock.now < deadline {
                scrollPosition.scrollTo(edge: .bottom)
                try? await Task.sleep(for: Theme.Timing.endIsCheckedEvery)
            }
            followsEnd = false
        }
    }

    /// Putting the room down: the draft, the listeners, the camera, the microphone.
    ///
    /// Called from the two ways out, which are not the same way. Ordinarily the view simply
    /// disappears and `onDisappear` does this. But "Leave" on the info screen unwinds the room from
    /// *underneath* a screen that is still pushed over it, and `onDisappear` deliberately does
    /// nothing while a screen is pushed over the room — so that path calls this itself. Guarded so
    /// that the two cannot both land: leaving pops the info screen as well, and the disappearance
    /// that follows would otherwise save the draft a second time into a room the user has left.
    private func tearDown() {
        guard !hasTornDown else { return }
        hasTornDown = true

        // The half-written sentence goes with the room, into the same encrypted store the
        // conversation lives in — see `TimelineStore.saveDraft`. Captured by value here, and
        // the store outlives the view, so this finishes after the screen has gone.
        //
        // Unless the words in the box are not the user's. An *edit* fills the composer with
        // the message being changed, and `cancelContext()` says why that draft must never
        // outlive the edit: come back to it with no edit in progress and the composer is
        // holding a message that has already been sent, ready to be sent again as a new one.
        // Every other way out of an edit knew this. Walking out of the room did not — so
        // editing "Привет", changing your mind, and leaving put a second "Привет" in the
        // conversation the next time the send button was pressed.
        let isEditing = composerContext?.isEditing == true
        let unsent = isEditing ? "" : draft
        let timeline = timeline
        Task { await timeline.saveDraft(unsent) }

        timeline.stop()
        videoNote.cancel()
        voice.cancel()
        lighting?.cancel()
        spinnerRest?.cancel()
    }

    /// What fills a conversation that has nothing in it.
    ///
    /// Three states, and telling them apart is the whole job. A room that failed to open, a
    /// room that has not opened *yet*, and a room that is genuinely empty are the same blank
    /// screen — and blank is the wrong answer to two of the three. The first is the only one
    /// the user can do anything about, so it is the only one with a button; the third is not
    /// a problem at all, so it says so and invites them to write something.
    ///
    /// The middle one draws nothing, and that is the point. A spinner in the centre of a
    /// screen the user has just opened is the app saying "wait" about work that takes a
    /// moment — it flashes, it pulls the eye to the middle of a conversation that is about
    /// to fill from the bottom, and it makes the room feel slower than it is. The empty room
    /// still has to be told apart from the unloaded one, though, hence the branch: without
    /// it the screen would say "no messages yet" to someone whose first page is half a
    /// second away.
    @ViewBuilder
    private var placeholder: some View {
        if timeline.didFailToLoad {
            ContentUnavailableView {
                Label(Strings.Room.loadFailedTitle, systemImage: "exclamationmark.triangle")
            } description: {
                Text(Strings.Room.loadFailedMessage)
            } actions: {
                Button(String(app: Strings.Room.tryAgain)) {
                    Task { await timeline.retryLoading() }
                }
                .buttonStyle(.primaryAction)
            }
        } else if !timeline.hasLoaded {
            EmptyView()
        } else if timeline.rows.isEmpty {
            ContentUnavailableView(String(app: Strings.Room.emptyTitle),
                                   systemImage: "bubble.left.and.bubble.right",
                                   description: Text(Strings.Room.emptyMessage))
        }
    }

    /// The line under the room's name in the header.
    ///
    /// In a room, how many people are in it. In a chat with one other person, their Matrix
    /// ID — *not* "last seen five minutes ago", which this app cannot honestly say: the
    /// Rust SDK exposes no presence over FFI at all, and the only timestamp we could reach
    /// for is the last message in the conversation, which is a different fact wearing
    /// presence's clothes. Someone who has been reading all morning without typing is not
    /// "last seen at 09:14".
    ///
    /// Nil until the room has synced enough to say. A header that reads "0 participants"
    /// for a moment is worse than one that is briefly just a name.
    /// What the line under the room's name says.
    ///
    /// Somebody typing displaces it, and displaces it rather than joining it, because the line has
    /// room for one fact and this is the more urgent one — a member count is true all day, and
    /// "Аня печатает…" is true for four seconds and is about to become a message.
    ///
    /// In a one-to-one chat their name is already the *title*, so naming them again here would say
    /// it twice; the line just says that writing is happening. In a room full of people it names
    /// them, because that is the whole of what you want to know.
    private var headerSubtitle: String? {
        if let typing = typingSubtitle {
            return typing
        }
        if timeline.isOneToOne {
            return timeline.directCounterpartID
        }
        guard timeline.memberCount > 0 else { return nil }
        return String(app: Strings.Room.participants(timeline.memberCount))
    }

    private var typingSubtitle: String? {
        let names = timeline.typing
        guard !names.isEmpty else { return nil }

        if timeline.isOneToOne {
            return String(app: Strings.Room.typing)
        }
        return String(app: Strings.Room.typingBy(names.formatted(.list(type: .and))))
    }

    private var composer: some View {
        MessageComposer(draft: $draft,
                        context: composerContext,
                        onCancelContext: cancelContext,
                        onSend: send,
                        onStartVideoNote: startVideoNote,
                        onFinishVideoNote: finishVideoNote,
                        onCancelVideoNote: cancelVideoNote,
                        onLockVideoNote: {
                            isVideoNoteLocked = true
                            isHoldingVideoNote = false
                        },
                        onStartVoice: { Task { await startVoice() } },
                        onFinishVoice: { Task { await finishVoice() } },
                        onCancelVoice: cancelVoice,
                        onLockGesture: { lock = $0 },
                        voice: voiceRecording,
                        onChoosePhoto: { isChoosingPhoto = true },
                        onChooseFile: { isChoosingFile = true },
                        onChooseLocation: { isChoosingLocation = true })
    }

    private var readOnlyBanner: some View {
        ReadOnlyBanner()
    }

    /// The camera, over the conversation rather than instead of it.
    ///
    /// An overlay on the *screen* and not on the composer, which is the whole reason it is up
    /// here: the composer is handed down as a `safeAreaInset`, and an overlay on it is clipped
    /// to the bar. This one has to cover the room — that is what it is for.
    @ViewBuilder
    private var videoNoteOverlay: some View {
        if isRecordingVideoNote {
            VideoNoteComposer(recorder: videoNote,
                              isHolding: $isHoldingVideoNote,
                              isLocked: $isVideoNoteLocked,
                              lock: lock,
                              onCancel: cancelVideoNote) { url in
                await timeline.send(video: url, replyingTo: replyID)
                cancelContext()
                // The same tidying up as cancelling, and `cancel()` is what does it: there is
                // nothing left to throw away by the time this runs, and what it is being asked
                // for is the other half of that job — turn the camera off.
                cancelVideoNote()
            }
            .transition(.opacity)
        }
    }

    // MARK: - Recording a video note

    /// The finger came down on the video button. Up comes the camera, and it starts recording
    /// the moment it is ready — see `VideoNoteComposer`.
    private func startVideoNote() {
        isHoldingVideoNote = true
        isVideoNoteLocked = false
        withAnimation(.smooth(duration: 0.25)) { isRecordingVideoNote = true }
    }

    /// The finger came up. That means send — unless the recording has been let go of, in which
    /// case the sheet is in charge of it now and lifting a finger means nothing.
    ///
    /// `stop()` is what sends: the recorder crops the clip square and hands it to the closure
    /// the sheet gave it, which uploads and dismisses. A `stop()` on a recorder that never got
    /// going is a no-op, which is what a tap on the button amounts to — the sheet stays up, and
    /// the shutter inside it is there to be held.
    private func finishVideoNote() {
        isHoldingVideoNote = false
        guard !isVideoNoteLocked else { return }
        videoNote.stop()
    }

    /// Cancelled. The clip is thrown out and the camera goes with it.
    private func cancelVideoNote() {
        isHoldingVideoNote = false
        isVideoNoteLocked = false
        videoNote.cancel()
        withAnimation(.smooth(duration: 0.25)) { isRecordingVideoNote = false }
    }

    // MARK: - Recording a voice message

    /// What the composer draws while somebody is speaking, and nil the rest of the time.
    ///
    /// `.stopped` counts, and has to: it is a recording iOS ended without asking — the cap, a phone
    /// call, the app being put away — and what was said is still there and still worth sending. The
    /// strip stays up so there is something to press send on, and the clock it shows has stopped,
    /// which is the truth.
    ///
    /// `.starting` counts too, and for the opposite reason: there the microphone is not open *yet*.
    /// It is the few hundred milliseconds the phone spends waking the audio session, and the strip
    /// belongs on the screen for all of them — the hold has taken, the phone has said so with a tap
    /// on the hand, and the one thing that must not happen next is nothing. The clock reads 0:00 and
    /// the waveform is empty, because that is exactly what has been recorded so far.
    private var voiceRecording: VoiceRecording? {
        guard voice.state == .starting || voice.state == .recording || voice.state == .stopped else {
            return nil
        }
        return VoiceRecording(elapsed: voice.elapsed,
                              waveform: voice.waveform,
                              isLive: voice.state != .stopped)
    }

    private func startVoice() async {
        await voice.start()

        // The microphone was refused. Say so — a hold that produces nothing, with no explanation,
        // is the app appearing to be broken when in fact it is being obedient.
        if voice.state == .denied {
            problem = .microphone
        }
    }

    /// The finger came up: send what was said.
    ///
    /// `finish()` hands back nil for a recording too short to be a message — a thumb that brushed
    /// the button — and nil is simply nothing to send. It also hands back a file, in plaintext,
    /// which is deleted the moment the upload has been handed to the send queue.
    private func finishVoice() async {
        await sendVoice()
    }

    /// Ending a recording is a change to the recorder, and the composer only *watches* the
    /// recorder — so the strip going away has to be animated from here, where the change is made.
    /// An `.animation(value:)` on the composer is not enough on its own: the value it watches is
    /// derived from an `@Observable` mutated outside any animation transaction, and what SwiftUI
    /// does with that is redraw. Which is what it was doing: a minute of somebody's voice
    /// vanishing between one frame and the next.
    private func sendVoice() async {
        guard let recording = withAnimation(.smooth(duration: 0.25), { voice.finish() }) else { return }

        // Safe to delete the moment the send returns, and it is worth knowing *why*, because it
        // stopped being safe for the obvious reason. `send(voice:)` no longer waits for the upload —
        // an attachment goes into the send queue and leaves when the network does — so this file is
        // no longer being held open by anybody we are waiting on. What makes it safe is the queue
        // itself: the SDK copies the content into its own encrypted store the instant the attachment
        // is queued ("the file's content is immediately cached in the EventCacheStore"), before any
        // upload is attempted. The recording on disk has done its job by then.
        //
        // And it must go. It is a minute of somebody's voice sitting unencrypted in a temporary
        // directory; the copy the queue keeps is inside the encrypted store, and this one is not.
        defer { try? FileManager.default.removeItem(at: recording.url) }

        await timeline.send(voice: recording.url,
                            duration: recording.duration,
                            waveform: recording.waveform,
                            replyingTo: replyID)
        cancelContext()
    }

    private func cancelVoice() {
        withAnimation(.smooth(duration: 0.25)) { voice.cancel() }
    }

    /// One row of the conversation: a message, the date above it, or a note about something
    /// that happened.
    ///
    /// Out of the `ForEach` and into a function of its own, and not for tidiness: with the
    /// switch and all nine of the message's callbacks written inline, the Swift type checker
    /// gives up on the whole body — "unable to type-check this expression in reasonable time" —
    /// because every closure it has to infer multiplies through the view tree around it.
    @ViewBuilder
    private func view(for row: TimelineRow,
                      followsEvent: Bool,
                      opensDay: Bool,
                      arrives: Bool,
                      in scroll: ScrollViewProxy) -> some View {
        switch row {
        case let .dayDivider(divider):
            DayDividerView(date: divider.date)
        case let .event(event):
            RoomEventRow(event: event, followsEvent: followsEvent, opensDay: opensDay)
        case let .message(message):
            messageRow(message, opensDay: opensDay, arrives: arrives, in: scroll)
        }
    }

    /// A row, and the two facts about its neighbours it needs: whether the row above it was
    /// another service note, and whether it was a date. The first closes the gap inside a run of
    /// notes; the second stops the first row of a day paying for air the date has already given
    /// it. Neither can be worked out by the row alone, and asking for them row by row inside the
    /// `ForEach` would walk the timeline once per row.
    private struct PlacedRow: Identifiable {
        let row: TimelineRow
        let followsEvent: Bool
        let opensDay: Bool
        /// Whether this row is arriving *now* — see `newestRowID`, and `MessageRow.arrivesAnimated`.
        let arrives: Bool
        /// What the row is drawn under, which for a message of ours that the server has just
        /// echoed is the ID its bubble already had — see `TimelineStore.viewIdentity(of:)`. It
        /// is the identity SwiftUI keys the view on, and keeping it steady is what lets a
        /// message you sent finish the arrival it started.
        let id: String
    }

    private var placedRows: [PlacedRow] {
        let rows = timeline.rows
        // Everything past where the conversation used to end is arriving; everything else is
        // either already here or was added above, which is history and not an arrival. Found
        // once, here, rather than asked row by row — the search is a walk of the timeline, and
        // one per row would be a walk per row.
        //
        // Worked out while the view is being built and *not* in an `onChange`, which is the
        // mistake this replaced. A transition is chosen at the instant a row is inserted, and a
        // handler that runs after the change has been applied is a handler that answers "is this
        // arriving?" one pass too late — the row is already on screen, unanimated, and nothing
        // will ask again.
        let firstArrival = MessageArrivals.firstArriving(in: rows.map(\.id), after: newestRowID)

        var previousWasEvent = false
        var previousWasDivider = false
        return rows.enumerated().map { index, row in
            let placed = PlacedRow(row: row,
                                   followsEvent: previousWasEvent,
                                   opensDay: previousWasDivider,
                                   arrives: hasSettled && index >= firstArrival,
                                   id: timeline.viewIdentity(of: row))
            if case .event = row { previousWasEvent = true } else { previousWasEvent = false }
            if case .dayDivider = row { previousWasDivider = true } else { previousWasDivider = false }
            return placed
        }
    }

    /// Bubbles on two sides, or the plain column — see `MessageLayout`. The one place in the app
    /// the choice is acted on: everything below here is one row or the other, and neither of them
    /// asks which it is.
    @ViewBuilder
    private func messageRow(_ message: Message,
                            opensDay: Bool,
                            arrives: Bool,
                            in scroll: ScrollViewProxy) -> some View {
        let handlers = handlers(for: message, in: scroll)
        let isPinned = timeline.isPinned(messageID: message.id)
        let isHighlighted = highlighted == message.id

        switch messageLayout {
        case .bubbles:
            MessageRow(message: message,
                       isOneToOne: timeline.isOneToOne,
                       handlers: handlers,
                       isPinned: isPinned,
                       opensDay: opensDay,
                       arrivesAnimated: arrives,
                       isHighlighted: isHighlighted)
        case .compact:
            // No `isOneToOne`: the plain column says who spoke in every conversation, because
            // nothing else there does. See `CompactMessageRow`.
            CompactMessageRow(message: message,
                              handlers: handlers,
                              isPinned: isPinned,
                              opensDay: opensDay,
                              arrivesAnimated: arrives,
                              isHighlighted: isHighlighted)
        }
    }

    /// What the row is allowed to ask of the room — see `MessageHandlers`.
    ///
    /// Built in a function of its own, and the comment above `view(for:followsEvent:in:)` says
    /// why: written inline, these closures are what the type checker gives up on.
    private func handlers(for message: Message, in scroll: ScrollViewProxy) -> MessageHandlers {
        MessageHandlers(
            onRetry: { Task { await timeline.retrySending(messageID: message.id) } },
            onToggleReaction: { emoji in
                Task { await timeline.toggleReaction(messageID: message.id, key: emoji) }
            },
            onDelete: { Task { await timeline.delete(messageID: message.id) } },
            onDiscard: { Task { await timeline.discard(messageID: message.id) } },
            onReply: { startReplying(to: message) },
            onEdit: { startEditing(message) },
            onTogglePin: { Task { await togglePin(message) } },
            onOpenReply: { eventID in
                // The quoted message may be far above, and it may not be loaded at all. It used
                // to be a bare `scrollTo`, which on an ID the list does not hold is a no-op — so
                // a reply to anything older than the first page did nothing when pressed. It goes
                // the way a pinned message does now, through `jumpTarget`, which pulls history in
                // until the message is there to go to.
                //
                // And the keyboard goes down: the reader has asked to *read* something, and on a
                // phone the keyboard is half the screen that message would be shown in.
                Keyboard.dismiss()
                jumpTarget = eventID
            },
            onReport: { reason in Task { await timeline.report(messageID: message.id, reason: reason) } }
        )
    }

    /// The pill that says something was said while you were reading further up, and takes you to
    /// it. Glass, and on the navigation layer where glass belongs: it floats over the conversation
    /// and is not part of it.
    private func jumpToNewest() -> some View {
        Button {
            goToNewest()
            // Not cleared here — arriving is what clears it, and arriving is what the scroll
            // geometry reports. Clearing it on the press would take the pill away from somebody
            // whose scroll had not started yet.
        } label: {
            HStack(spacing: Theme.Spacing.tight) {
                Image(systemName: "arrow.down")
                    .font(.caption.weight(.semibold))
                Text(Strings.Room.jumpToNewest)
                    .font(.caption.weight(.medium))
            }
            .padding(.horizontal, Theme.Spacing.normal)
            .padding(.vertical, Theme.Spacing.close)
            // Plain glass, not the accent.
            //
            // The tint is reserved for *the* primary action — the send button, "Continue" on
            // sign-in — and this is not one. It is a notice that something was said while you
            // were reading, and it is offering to take you there; painting it in the same colour
            // as the button that sends a message put two loudest-things-on-the-screen on the
            // screen at once, a few points apart, both round, both accented. The eye had to be
            // told which was which. Glass says "floating control" without claiming to be the
            // point of the room, and the point of the room is the conversation behind it.
            .navigationGlass(in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
    }

    /// The way to the rest of a conversation the reader cannot scroll to.
    ///
    /// Everywhere else, older messages are asked for by scrolling to the top, and that is the right
    /// gesture: it is the one people already make. But it is a gesture only a scrollable room can
    /// receive — and a room that came up holding two messages is shorter than the screen it is on.
    /// There is nothing to pull, the geometry never changes, so nothing ever asks for history
    /// again and the room stays two messages long for as long as it is open. The store knows when
    /// it is in that state (`needsMoreHistory`); this is what it offers when it is.
    ///
    /// A real row at the head of the list, not an overlay like the spinner. The spinner is a thing
    /// that comes and goes twice a page and must not shove the conversation about; this appears
    /// once, in a room with nothing above the first message anyway, and stays until it is pressed
    /// or until it has done its job. It *is* the top of the conversation, so that is where it goes.
    @ViewBuilder
    private var loadEarlier: some View {
        if timeline.needsMoreHistory {
            Button {
                Task { await timeline.loadMoreHistory() }
            } label: {
                Text(Strings.Room.loadEarlier)
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, Theme.Spacing.normal)
                    .padding(.vertical, Theme.Spacing.close)
                    .navigationGlass(in: .capsule)
                    .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .padding(.vertical, Theme.Spacing.normal)
        } else if timeline.historyIsStranded {
            // The same place, and deliberately not the same thing. There is more of this
            // conversation and we could not fetch it — so what goes here is the reason, not an
            // offer we cannot keep. Pressing it is still allowed, because a network can come back
            // between one glance at the screen and the next.
            Button {
                Task { await timeline.loadMoreHistory() }
            } label: {
                Text(Strings.Room.earlierUnavailable)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Theme.Spacing.normal)
                    .padding(.vertical, Theme.Spacing.close)
            }
            .buttonStyle(.plain)
            .padding(.vertical, Theme.Spacing.normal)
        }
    }

    /// The end of the conversation, asked of the screen rather than worked out from it.
    ///
    /// Everything that turns on "is the reader at the end" — following an arriving message,
    /// offering the way down — used to be answered by a sum over content size, offset, container
    /// and insets, and that sum has one answer per convention about what those four things mean.
    /// This has one answer: the floor under the last message is either in front of the reader or
    /// it is not. See `isAtNewest`.
    private var endMarker: some View {
        Color.clear
            .frame(height: Theme.Border.hairline)
            .onScrollVisibilityChange(threshold: 0.01) { visible in
                endIsOnScreen = visible
            }
    }

    /// The way back down when nothing has arrived — just a room you have read a long way up.
    ///
    /// A circle with an arrow in it and no words, because there is nothing to say: the pill above
    /// exists to *tell* you something and therefore has a sentence in it, and this exists only to
    /// take you somewhere.
    private func scrollToBottom() -> some View {
        Button {
            goToNewest()
        } label: {
            Image(systemName: "chevron.down")
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(width: Theme.Size.composerControl, height: Theme.Size.composerControl)
                .navigationGlass(in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(Strings.Room.scrollToBottom))
    }

    private func goToNewest() {
        // The end of the conversation, not the last row — the same distinction as above, and
        // here it decided whether the button could put itself away. Sent to the last message,
        // the reader landed a composer's height short of the end, the end marker stayed off
        // screen, and the button that had just taken them there was still on top of it.
        withAnimation(.smooth) { scrollPosition.scrollTo(edge: .bottom) }
    }

    /// How far back a jump is willing to dig for a message that is not loaded. Ten pages of
    /// twenty-five events is a deep enough reach for anything anybody has actually pinned, and a
    /// shallow enough one that a room does not appear to hang while it rewinds.
    private static let jumpPages = 10

    /// Lights the message the conversation has just jumped to, and puts it out again a moment
    /// later.
    ///
    /// The timer is held so that a second jump can call the first one off. Without that, pressing
    /// two quotes in quick succession leaves the first message's timer still running, and it
    /// reaches its `sleep` a second later and puts out a light it did not light — the message the
    /// user is looking at right now goes dark while they are looking at it.
    private func light(_ eventID: String) {
        lighting?.cancel()
        highlighted = eventID

        lighting = Task {
            try? await Task.sleep(for: .seconds(Theme.Timing.highlight))
            guard !Task.isCancelled else { return }
            highlighted = nil
        }
    }

    // MARK: - Answering, changing, pinning

    /// The message an attachment or a new message is answering, and nil when it is answering
    /// nothing. An *edit* is not a reply, which is why this is not simply "the context's
    /// message": starting an edit and then sending a photo must not quietly attach the photo
    /// as an answer to the message being edited.
    private var replyID: String? {
        guard case let .replying(message)? = composerContext else { return nil }
        return message.id
    }

    private func startReplying(to message: Message) {
        composerContext = .replying(message)
    }

    /// Begins an edit, and fills the box with what the message currently says — which is the
    /// whole point: an edit that started from an empty field would be a rewrite, and the user
    /// pressed "Edit" because they want to change a word.
    private func startEditing(_ message: Message) {
        guard let text = message.editableText else { return }
        composerContext = .editing(message)
        draft = text
    }

    /// Backs out of a reply or an edit.
    ///
    /// An abandoned *edit* takes its draft with it, and this is the one place the draft is
    /// thrown away. It has to be: the box was filled with the old message by the app, not by
    /// the user, and leaving those words behind would mean cancelling an edit and finding the
    /// message you were editing sitting in the composer, ready to be sent again as a new one.
    /// An abandoned reply keeps the draft, because every word in it is the user's own.
    private func cancelContext() {
        if case .editing = composerContext { draft = "" }
        composerContext = nil
    }

    private func togglePin(_ message: Message) async {
        if timeline.isPinned(messageID: message.id) {
            await timeline.unpin(messageID: message.id)
        } else {
            await timeline.pin(messageID: message.id)
        }
    }

    /// What the photo picker hands back, and what becomes of it.
    ///
    /// Nothing here fails quietly. It used to: three `guard`s returned on their own, and a
    /// photo that could not be read produced a tap, a picker, and then nothing at all — no
    /// bubble, no error, no line in any log. That is the state this whole app is written
    /// against, and it is why a failure to *read* a picture now says so on screen.
    private func sendPicked(_ item: PhotosPickerItem) async {
        let data: Data?
        do {
            data = try await item.loadTransferable(type: Data.self)
        } catch {
            Log.media.error("the photo library would not hand over the item: \(Log.describe(error), privacy: .public)")
            problem = .unreadableAttachment
            return
        }

        guard let data else {
            Log.media.error("the photo library returned no bytes for the picked item")
            problem = .unreadableAttachment
            return
        }

        let isVideo = item.supportedContentTypes.contains { $0.conforms(to: .movie) }
        let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? (isVideo ? "mp4" : "jpg")
        let filename = "\(UUID().uuidString).\(ext)"

        // A photo goes as bytes: no file, so nothing to write, delete, or race. A video still
        // needs one, because the duration and the frame that becomes its thumbnail can only
        // be read by `AVAsset`, and `AVAsset` reads a URL. That file is plaintext on disk, so
        // it lives exactly as long as the upload does.
        guard isVideo else {
            await timeline.send(photo: data, filename: filename, replyingTo: replyID)
            cancelContext()
            return
        }

        let url = URL.temporaryDirectory.appending(component: filename)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            Log.media.error("the video could not be staged for upload: \(Log.describe(error), privacy: .public)")
            problem = .unreadableAttachment
            return
        }
        // Gone as soon as the send returns, and still correct now that the send does not wait for
        // the upload: the queue copies the file into its own encrypted store as it takes it. See
        // `sendVoice`, where the same reasoning is set out at length.
        defer { try? FileManager.default.removeItem(at: url) }

        await timeline.send(video: url, replyingTo: replyID)
        cancelContext()
    }

    private func sendPickedFile(_ url: URL) async {
        // A file the user picked lives outside our sandbox until we say otherwise.
        let needsScope = url.startAccessingSecurityScopedResource()
        defer { if needsScope { url.stopAccessingSecurityScopedResource() } }

        await timeline.send(file: url, replyingTo: replyID)
        cancelContext()
    }

    /// Send, apply an edit, or answer — the same button, and what it does depends on what the
    /// composer is holding.
    ///
    /// The box is cleared *first*, before the send is awaited, and it has to be: a send goes
    /// into the SDK's encrypted queue and can take as long as the network does, and a composer
    /// that holds the user's words until the server has them is a composer that appears frozen
    /// on a slow connection. The queue is what guarantees the message goes; the screen does not
    /// have to stand guard over it.
    private func send() {
        let text = draft
        let context = composerContext

        // An empty edit is the one thing the send button refuses — it disables itself, because a
        // blank edit is not an edit and the core drops it anyway. A keyboard Return reaches here
        // past that disabled button (on macOS, where Return submits), so it is refused in the same
        // breath: the composer is left exactly as it was, still holding the edit.
        if case .editing = context, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return }

        draft = ""
        composerContext = nil

        Task {
            switch context {
            case let .editing(message):
                await timeline.edit(messageID: message.id, text: text)
            case let .replying(message):
                await timeline.send(text: text, replyingTo: message.id)
            case nil:
                await timeline.send(text: text)
            }

            // The words have gone; there is nothing left to come back to. Without this the room
            // would greet the user with the message they had *already sent*, sitting in the
            // composer waiting to be sent a second time.
            await timeline.clearDraft()
        }
    }
}

// The lock used to live here as a button of its own, and pressing it explained the room's
// privacy in a popover. It is now a plain glyph inside `RoomHeader` — a button inside a
// button is ambiguous to the eye and a mess for VoiceOver — and the sentence it used to
// show has a row to itself on `RoomInfoView`, one press away.

struct DayDividerView: View {
    let date: Date

    var body: some View {
        Text(Self.label(for: date))
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            // Enough air to read as a break in the conversation, and no more. At `roomy` on both
            // sides the date was holding a band of empty screen the height of a message either
            // side of it, so a day with two lines in it looked like a day with a hole in it.
            //
            // The air is uneven on purpose: the gap belongs above the date, because the date
            // closes the day before it and *opens* the one under it. Sitting equidistant, it
            // floated between two days and belonged to neither.
            .padding(.top, Theme.Spacing.roomy)
            .padding(.bottom, Theme.Spacing.close)
            .frame(maxWidth: .infinity)
    }

    /// "Сегодня", "Вчера", then "12 июля" — and with the year once the date leaves this
    /// one, because a bare "12 июля" from three years ago dates nothing.
    ///
    /// The weekday is gone on purpose. Nobody recalls a conversation as *Sunday, 12 July*;
    /// the two days worth naming are named, and the rest are read as dates.
    static func label(for date: Date,
                      now: Date = .now,
                      calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return String(localized: Strings.Room.today)
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return String(localized: Strings.Room.yesterday)
        }
        let sameYear = calendar.isDate(date, equalTo: now, toGranularity: .year)
        return date.formatted(sameYear ? .dateTime.day().month(.wide)
                                       : .dateTime.day().month(.wide).year())
    }
}
