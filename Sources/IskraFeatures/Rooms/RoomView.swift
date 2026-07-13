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

    /// Whether the reader is standing at the newest message, which is what decides if an
    /// arriving message is allowed to move the conversation.
    ///
    /// It used to be allowed unconditionally, and that is a bad way to lose your place: you
    /// scroll up to read something from last week, somebody says "ok" in the room, and you are
    /// thrown back to the bottom. In a busy room it happens again on every message, and there
    /// is no way to read anything old at all.
    ///
    /// Starts true, because a room opens on its newest message — see `hasAnchored`.
    @State private var isAtNewest = true

    /// The room-info screen, built when the header is first pressed and kept afterwards.
    ///
    /// Held rather than made on the spot, because `navigationDestination` evaluates its
    /// destination whenever the view around it redraws — and a fresh `RoomDetailsStore`
    /// each time would re-fetch the member list on every keystroke in the composer behind
    /// it.
    @State private var details: RoomDetailsStore?
    @State private var isShowingDetails = false

    /// The width the messages have to live in. See `EnvironmentValues.timelineWidth`.
    @State private var timelineWidth: CGFloat = 0

    /// The message the conversation has just been sent to by pressing a quote, lit until the
    /// reader has had time to see which one it is — and the timer that puts it out. See `light`.
    @State private var highlighted: String?
    @State private var lighting: Task<Void, Never>?

    /// Trustworthy *here*, unlike in the sidebar. `RoomView` fills the split view's detail
    /// column, so the size class it reads is the width of the space it actually draws in —
    /// and how much room the title bar has is precisely the question the header's shape
    /// turns on. See `RoomListView.isSidebar` for the case where this reasoning goes wrong.
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// The room-info store, made on demand rather than passed in ready — it is a screenful
    /// of requests, and most conversations are read without ever opening it. It comes from
    /// the session, because it needs the `Client` as well as the room: a room's
    /// notification rule lives on the account.
    var makeDetails: () -> RoomDetailsStore?

    /// Leaving a room takes this whole screen away with it, and this screen cannot do
    /// that: the room it is showing is chosen above, in the split view. Same shape as
    /// sign-out in `RoomListView` — the act is reported upwards and performed there.
    var onLeave: () -> Void

    public init(timeline: TimelineStore,
                makeDetails: @escaping () -> RoomDetailsStore?,
                onLeave: @escaping () -> Void) {
        _timeline = State(initialValue: timeline)
        self.makeDetails = makeDetails
        self.onLeave = onLeave
    }

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

    public var body: some View {
        ScrollViewReader { scroll in
            ScrollView {
                LazyVStack(spacing: 0) {
                    // Only while something is actually being fetched.
                    //
                    // This used to be shown whenever `canLoadMore` was true — and that is
                    // true from the moment a room opens until the user has paginated all
                    // the way back to the day it was created, which for any real
                    // conversation is never. So every chat wore a spinner at the top
                    // forever, promising work that was not happening. The spinner also
                    // *was* the trigger: it started pagination when it appeared, which is
                    // why it could not simply be hidden. Scrolling near the top is what
                    // asks for more history now, so the two jobs are separate and the
                    // spinner is free to tell the truth.
                    if timeline.isPaginating {
                        ProgressView()
                            .padding()
                    }

                    ForEach(placedRows) { placed in
                        view(for: placed.row, followsEvent: placed.followsEvent, in: scroll)
                            .id(placed.id)
                    }
                }
                // A message leaving the conversation is the one change here worth animating.
                //
                // There are two ways it can go, and they look different because they *are*
                // different. A redaction leaves the row behind — the bubble collapses into
                // the grey "message deleted" line, which `MessageRow` animates itself. A
                // message that never left the device is lifted out of the send queue and the
                // row goes with it, and that removal is a change to this array, so only the
                // list around it can animate it: hence the transition on the row and the
                // animation scope here.
                //
                // Scoped to the identities, not to the rows themselves. Every delivery tick
                // and every reaction rewrites a row without changing the shape of the list,
                // and animating the whole stack each time one of them lands would set the
                // conversation quietly shifting under the reader for no reason.
                .animation(.smooth(duration: Theme.Timing.deletion), value: timeline.rows.map(\.id))
                .padding(.horizontal, Theme.Spacing.normal)
                // The composer floats over the timeline on glass, so the last message
                // must be able to scroll clear of it — but only just. The composer already
                // carries its own padding, and a generous gap on top of that reads as the
                // conversation having ended some way above the bar you answer it in.
                .padding(.bottom, Theme.Spacing.close)
            }
            .defaultScrollAnchor(.bottom)
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
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y < Theme.Size.paginationReach
            } action: { _, isNearTop in
                guard isNearTop, hasAnchored else { return }
                Task { await timeline.loadMore() }
            }
            // Opening a room puts it on its newest message, once — the moment the first
            // fetch has come back with something to show. `initial: true` covers a room
            // whose store was already open and full before this view was ever built.
            .onChange(of: isReady, initial: true) { _, ready in
                guard ready, !hasAnchored, let last = timeline.rows.last?.id else { return }
                hasAnchored = true
                // Not animated: this is where the room *opens*, not somewhere it travels to.
                scroll.scrollTo(last, anchor: .bottom)
            }
            // Is the reader at the newest message? Measured the same way the pagination trigger
            // above is, from the other end of the scroll view.
            .onScrollGeometryChange(for: Bool.self) { geometry in
                let distanceFromBottom = geometry.contentSize.height
                    - geometry.contentOffset.y
                    - geometry.containerSize.height
                return distanceFromBottom < Theme.Size.newestReach
            } action: { _, isAtBottom in
                isAtNewest = isAtBottom
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
                guard isAtNewest || timeline.rows.last?.message?.isOwn == true else { return }
                withAnimation(.smooth) { scroll.scrollTo(last, anchor: .bottom) }
            }
            // Over the timeline but *under* the composer, which is a safe-area inset added
            // further down: a placeholder that covered the box you type into would be
            // telling you to say something and hiding the way to say it.
            .overlay { placeholder }
        }
        .safeAreaInset(edge: .bottom) {
            composer
        }
        // Over everything, composer included: while the camera is up, the room is the thing
        // being answered rather than the thing being used.
        //
        // The fade is a `withAnimation` at the two places the flag moves, and *not* an
        // `.animation(value:)` here: this is the outermost view in the room, and an implicit
        // animation on it would animate every animatable value in the whole subtree — the
        // timeline, the rows, the composer — each time the camera came up.
        .overlay { videoNoteOverlay }
        // The strip at the top of the room, above the conversation and below the toolbar.
        // Present only when there is something pinned — a room with nothing pinned should not
        // give up a row of its screen to say so.
        .safeAreaInset(edge: .top) {
            if !timeline.pinnedEventIDs.isEmpty, let pinned {
                PinnedStrip(pinned: pinned) { message in
                    // Pressing the strip goes to the message. Pressing the count opens the
                    // list — that is the second button inside `PinnedStrip`.
                    isShowingPinned = true
                    _ = message
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.smooth, value: timeline.pinnedEventIDs)
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
                               privacy: timeline.privacy,
                               subtitle: headerSubtitle,
                               onOpenDetails: openDetails)
                }
                .sharedBackgroundVisibility(.hidden)
            }
        }
        .navigationDestination(isPresented: $isShowingDetails) {
            if let details {
                RoomInfoView(details: details, onLeave: onLeave)
            }
        }
        .navigationDestination(isPresented: $isShowingPinned) {
            if let pinned {
                PinnedMessagesView(pinned: pinned, isDirectChat: timeline.isDirectChat)
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
        .task {
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
        .onDisappear {
            timeline.stop()
            videoNote.cancel()
            voice.cancel()
            lighting?.cancel()
        }
        .alert(Text(Strings.Room.sendFailedTitle),
               isPresented: .init(get: { timeline.sendFailure != nil },
                                  set: { if !$0 { timeline.sendFailure = nil } })) {
            Button(String(app: Strings.Problem.ok), role: .cancel) { timeline.sendFailure = nil }
        } message: {
            if let failure = timeline.sendFailure { Text(failure) }
        }
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
                .buttonStyle(.borderedProminent)
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
    private var headerSubtitle: String? {
        if timeline.isDirectChat {
            return timeline.directCounterpartID
        }
        guard timeline.memberCount > 0 else { return nil }
        return String(app: Strings.Room.participants(timeline.memberCount))
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
                        voice: voiceRecording,
                        onChoosePhoto: { isChoosingPhoto = true },
                        onChooseFile: { isChoosingFile = true },
                        onChooseLocation: { isChoosingLocation = true })
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
    private var voiceRecording: VoiceRecording? {
        guard voice.state == .recording else { return nil }
        return VoiceRecording(elapsed: voice.elapsed, waveform: voice.waveform)
    }

    private func startVoice() async {
        await voice.start()

        // The microphone was refused. Say so — a hold that produces nothing, with no explanation,
        // is the app appearing to be broken when in fact it is being obedient.
        if voice.state == .denied {
            timeline.sendFailure = Strings.Voice.needsMicrophone
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

    private func sendVoice() async {
        guard let recording = voice.finish() else { return }
        defer { try? FileManager.default.removeItem(at: recording.url) }

        await timeline.send(voice: recording.url,
                            duration: recording.duration,
                            waveform: recording.waveform,
                            replyingTo: replyID)
        cancelContext()
    }

    private func cancelVoice() {
        voice.cancel()
    }

    /// One row of the conversation: a message, the date above it, or a note about something
    /// that happened.
    ///
    /// Out of the `ForEach` and into a function of its own, and not for tidiness: with the
    /// switch and all nine of the message's callbacks written inline, the Swift type checker
    /// gives up on the whole body — "unable to type-check this expression in reasonable time" —
    /// because every closure it has to infer multiplies through the view tree around it.
    @ViewBuilder
    private func view(for row: TimelineRow, followsEvent: Bool, in scroll: ScrollViewProxy) -> some View {
        switch row {
        case let .dayDivider(divider):
            DayDividerView(date: divider.date)
        case let .event(event):
            RoomEventRow(event: event, followsEvent: followsEvent)
        case let .message(message):
            messageRow(message, in: scroll)
        }
    }

    /// A row, and the one fact about its neighbours it needs: whether the row above it was
    /// another service note. Only `RoomEventRow` uses it — to close the gap inside a run of
    /// notes — but the row cannot work it out alone, and asking for it row by row inside the
    /// `ForEach` would walk the timeline once per row.
    private struct PlacedRow: Identifiable {
        let row: TimelineRow
        let followsEvent: Bool
        var id: String { row.id }
    }

    private var placedRows: [PlacedRow] {
        var previousWasEvent = false
        return timeline.rows.map { row in
            let placed = PlacedRow(row: row, followsEvent: previousWasEvent)
            if case .event = row { previousWasEvent = true } else { previousWasEvent = false }
            return placed
        }
    }

    private func messageRow(_ message: Message, in scroll: ScrollViewProxy) -> some View {
        MessageRow(message: message,
                   isDirectChat: timeline.isDirectChat,
                   onRetry: { Task { await timeline.retrySending(messageID: message.id) } },
                   onToggleReaction: { emoji in
                       Task { await timeline.toggleReaction(messageID: message.id, key: emoji) }
                   },
                   onDelete: { Task { await timeline.delete(messageID: message.id) } },
                   onDiscard: { Task { await timeline.discard(messageID: message.id) } },
                   onReply: { startReplying(to: message) },
                   onEdit: { startEditing(message) },
                   onTogglePin: { Task { await togglePin(message) } },
                   isPinned: timeline.isPinned(messageID: message.id),
                   onOpenReply: { eventID in
                       // The quoted message may be far above, and it may not be loaded at all —
                       // `scrollTo` on an ID the list does not hold is a no-op, which is the
                       // right failure: nothing moves, and the user is where they were.
                       withAnimation(.smooth) { scroll.scrollTo(eventID, anchor: .center) }
                       light(eventID)
                   },
                   isHighlighted: highlighted == message.id)
    }

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
            Log.media.error("the photo library would not hand over the item: \(String(describing: error), privacy: .public)")
            timeline.sendFailure = Strings.Room.attachmentUnreadable
            return
        }

        guard let data else {
            Log.media.error("the photo library returned no bytes for the picked item")
            timeline.sendFailure = Strings.Room.attachmentUnreadable
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
            Log.media.error("the video could not be staged for upload: \(String(describing: error), privacy: .public)")
            timeline.sendFailure = Strings.Room.attachmentUnreadable
            return
        }
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
            .padding(.vertical, Theme.Spacing.roomy)
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
