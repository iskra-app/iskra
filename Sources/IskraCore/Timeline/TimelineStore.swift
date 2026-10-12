import Foundation
import Observation
import MatrixRustSDK

/// One room's conversation: the messages, and the ability to add to them.
///
/// Like the room list, the SDK streams this as diffs. Unlike the room list, the
/// items include local echoes — messages we have sent but the server has not yet
/// acknowledged — which is what lets a message appear instantly and then quietly
/// gain a "sent" tick.
@MainActor
@Observable
public final class TimelineStore {
    public private(set) var rows: [TimelineRow] = []
    public private(set) var isPaginating = false
    /// False once we have reached the beginning of the conversation.
    public private(set) var canLoadMore = true

    /// True once the SDK has told us what is in this room — *including* when the answer is
    /// "nothing".
    ///
    /// Without this, an empty conversation and one that has not arrived yet are the same
    /// empty array, and the screen has to guess which it is looking at. It always guesses
    /// wrong at least once: either it says "no messages yet" to someone whose messages are
    /// half a second away, or it shows a spinner forever to someone in a room that really
    /// is empty.
    public private(set) var hasLoaded = false

    /// The room could not be opened at all. Distinct from an empty room, and the only one
    /// of the two the user can do anything about.
    public private(set) var didFailToLoad = false

    /// The last page of history we asked for did not arrive.
    ///
    /// Not the same fact as `canLoadMore`, and the difference is what the reader sees. `canLoadMore`
    /// going false means the conversation has no more history — we paginated back to the day the room
    /// was made. This means there *is* more and we could not get it, which offline is the ordinary
    /// case: the event cache answers as far back as it goes, and then the next page needs the server.
    ///
    /// Both used to look identical from outside, because `page()` threw the error away. What the
    /// reader got was the "Show earlier messages" button — over a conversation whose earlier messages
    /// could not be shown, so pressing it did nothing but fail again, silently. A button that cannot
    /// work is worse than no button: it says the app could do this if only you pressed harder.
    public private(set) var didFailToPaginate = false

    /// Something the user asked the room to do, and it did not happen.
    ///
    /// An `ActionFailure`, like every other store's — and it was the one that was not. It used to be
    /// a bare `LocalizedStringResource?`, which meant the *model layer* was handing the view a
    /// finished sentence and the view could not use `.failureAlert($…)` with it, so `RoomView` built
    /// the alert by hand: seven lines reimplementing, slightly differently, the modifier three other
    /// screens share. A sentence is not a failure. A failure is a thing that happened, and the
    /// sentence is how it is said.
    public var failure: TimelineActionFailure?

    public let roomID: String

    /// What the room is called with no nickname over the top, kept so a rename made on this
    /// device can be undone without waiting for a sync that is never coming — see
    /// `LocalNames` and the observer in `start()`.
    private var serverRoomName = ""

    /// The subscription to nicknames changing. Held because dropping it unsubscribes.
    private var localNameObserver: LocalNameSubscription?
    public private(set) var privacy: PrivacyStatus = .unknown
    public private(set) var roomName: String = ""

    /// True when there is exactly one other person here. A conversation with one other
    /// person does not need their name and face repeated above every message they send —
    /// you know who they are, and the messages are on their side of the screen.
    ///
    /// A question about the room *right now*, not about what it is: invite a third person and
    /// the names come back, whether or not the chat began as a personal one. For what the room
    /// is, ask `kind`.
    public private(set) var isOneToOne = false

    /// What this room is — personal chat, group, or space. See `RoomKind`.
    public private(set) var kind: RoomKind = .group

    /// What the header above the conversation needs, and nothing more. The room *info*
    /// screen asks for the rest — members, topic, notifications — through
    /// `UserSession.details(forRoomID:)`, because that is a screenful of requests and this
    /// is a title bar.
    public private(set) var roomAvatarURL: String?

    /// What a generated stand-in face for this room is computed from, when there is no picture.
    /// See `RoomInfo.avatarSeed(besides:)` — in a personal chat it is the other person's ID.
    /// Nil until the room info has arrived: an empty seed is a valid string and would
    /// draw a creature of its own, so the face would change once, visibly, on load.
    public private(set) var roomAvatarSeed: String?
    /// The few members the server names for a group, so the header can draw the same cluster of
    /// faces the chat list does. Empty for anything that is not a group. See `RoomSummary.faces`.
    public private(set) var roomFaces: [RoomFace] = []
    public private(set) var memberCount = 0

    /// The other person's Matrix ID, in a chat that has exactly one other person.
    ///
    /// This is what the header shows under their name. It is deliberately *not* a "last
    /// seen" time: the Rust SDK exposes no presence at all over FFI, and a timestamp
    /// invented from their last message would say "online 5 minutes ago" about someone
    /// who has been reading over your shoulder in silence all day. The Matrix ID is the
    /// thing people actually ask each other for.
    public private(set) var directCounterpartID: String?

    /// Whether this account may add to the conversation. Starts true: until the room's
    /// power levels arrive, the safe assumption is the one that keeps the composer on
    /// screen. It flips only when the room definitively says no.
    public private(set) var canPost: Bool = true

    /// Who is typing, by the name they are known by in this room. Never includes you.
    ///
    /// Names rather than Matrix IDs, resolved here rather than in the view, because the view is
    /// not allowed to hold a `Room` and resolving one means asking the SDK. Empty is the normal
    /// state and the reason this is an array rather than a bool: a group can have three people
    /// typing at once, and "someone is typing" would be a worse thing to say than naming them.
    public private(set) var typing: [String] = []

    private var typingHandle: TaskHandle?

    /// The last thing we told the server about ourselves, so that we do not tell it again on
    /// every keystroke — a typing notice is a request, and one per character is a flood.
    private var isTellingThemWeType = false
    private var typingStopper: Task<Void, Never>?

    private let room: Room
    private let ownUserID: String
    private var timeline: Timeline?

    /// The SDK timeline, for the media-sending extension in `TimelineStore+Media`.
    /// Nil until `start()` has run.
    var liveTimeline: Timeline? { timeline }
    private var listenerHandle: TaskHandle?

    /// The one ordered road from the Rust callback thread to this actor — see `open()`. The
    /// continuation is what the listener yields into; the task is the only thing that reads it.
    private var diffContinuation: AsyncStream<UnsafeTransfer<[TimelineDiff]>>.Continuation?
    private var diffTask: Task<Void, Never>?

    /// Whether the room is being read again after the diffs stopped making sense — see `desynced`.
    /// It is a guard against a stampede: the batch that exposed the problem may hold twenty more
    /// impossible indices behind it, and they are all the same one fault.
    private var isResyncing = false
    private var sendQueueHandle: TaskHandle?
    private var roomInfoHandle: TaskHandle?
    private var items: [TimelineItem] = []

    /// Reactions we have handed to the send queue and not yet heard the end of, and the ones
    /// we know never got out of it. See `toggleReaction`.
    private var reactionsInFlight: [InFlightReaction] = []
    private var unsentReactions = UnsentReactions()

    /// The fetch that refills a conversation the SDK has just emptied — see `refill()`.
    private var refillTask: Task<Void, Never>?

    /// Messages the user has pressed send on that the SDK has not echoed back yet, shown at the
    /// end of the conversation so that pressing send puts the words on the screen rather than
    /// starting a wait for them. See `PendingSends`.
    private var pending = PendingSends()

    /// The page of history currently being fetched, if there is one. The re-entrancy guard for
    /// `page(showingSpinner:)` — and a task rather than a flag, so that a caller who arrives
    /// mid-flight can *wait* for the page instead of being turned away without one.
    ///
    /// It answers whether the pagination itself succeeded, which is not the same question as
    /// whether there is more history. See `PageOutcome`.
    private var pageInFlight: Task<Bool, Never>?

    /// True while that fetch is running, and the reason the screen does not flicker: see
    /// `rebuildRows()`.
    private var isRefilling = false

    /// The rows as they really are, published or not. `rows` is what the screen is showing,
    /// which during a refill is deliberately the conversation from a moment ago.
    private var latestRows: [TimelineRow] = []

    init(room: Room, ownUserID: String) {
        self.room = room
        self.ownUserID = ownUserID
        self.roomID = room.id()

        // A nickname is set on this device and travels nowhere, so no sync will ever arrive to
        // tell the header about it. This is how the name above the conversation changes the moment
        // somebody gives the person at the other end of it a different one — and how it changes
        // back. Subscribed in `init` rather than in `start()` because the header is drawn before
        // the timeline opens, and a room renamed from its own info screen is exactly the case.
        localNameObserver = LocalNames.observe { [weak self] changed in
            guard let self, changed == nil || changed == self.roomID else { return }
            self.roomName = LocalNames.name(for: self.roomID) ?? self.serverRoomName
        }
    }

    /// Which opening of this room we are on.
    ///
    /// Every asynchronous thing in this store outlives the room it was started for, and until this
    /// existed none of them knew it. `stop()` cancels handles and nils fields — but a `Task` that
    /// is *already awaiting* does not stop merely because somebody cancelled a variable, and when
    /// it comes back it writes what it learned into a store that has moved on. Three of them did:
    ///
    /// - `refill()` never checked `Task.isCancelled` at all, so after `stop()` and `start()` it
    ///   would wake up in the middle of the *new* `open()` and publish `latestRows` — which at that
    ///   moment is the fresh listener's empty reset. The conversation blinked empty in front of the
    ///   reader, and the guard in `rebuildRows()` that exists to prevent exactly that had been
    ///   turned off by the same zombie.
    /// - the pagination task held the *old* `timeline` in a local and wrote `canLoadMore` from it,
    ///   long after that timeline was gone.
    /// - `start()` guarded on `timeline == nil`, and assigned `timeline` two awaits later — so two
    ///   callers arriving in that window both opened the room: two listeners, two send-queue
    ///   subscriptions, two of everything, all feeding one `items` array.
    ///
    /// So the store counts its openings. `stop()` bumps the number; anything that spans an await
    /// takes it on the way in and checks it before writing anything the next opening owns.
    private var generation = 0

    /// The opening in flight, so a second caller waits for it instead of starting a rival one.
    private var opening: Task<Void, Error>?

    /// The pinned timeline over this same room, once anything has asked for one. See `pinned()`.
    private var pinnedStore: PinnedStore?

    public func start() async throws {
        // Somebody is already opening this room. Wait for them — and then stop, because the room
        // they opened is the room we wanted. Turning up second is the ordinary way this happens:
        // `RoomView.task` runs, the view is pushed over and comes back, and the task runs again
        // while the first is still two awaits from finishing.
        if let opening {
            try await opening.value
            return
        }

        guard timeline == nil else { return }

        didFailToLoad = false
        didFailToPaginate = false

        let generation = self.generation
        let task = Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                try await self.open()
            } catch {
                // A `stop()` while we were opening is not a failure to open. It is the reader
                // walking away, and the room they walked away from is already torn down.
                guard generation == self.generation else { return }

                // Recorded as well as thrown. The screen needs to be able to say "this chat
                // didn't open" and offer to try again — `try?` at the call site would swallow
                // the failure and leave it showing an empty room instead, which is a lie about
                // a conversation that may be full of messages.
                self.didFailToLoad = true

                // And everything the half-finished `open()` had already put in place goes with
                // it. It used to be three fields cleared by hand, which missed the listener and
                // the room-info subscription — `open()` registers those *before* the call that
                // can throw, so a room that failed on its way in left them running.
                self.stop()

                throw error
            }
        }

        opening = task

        defer {
            // Only if it is still ours. A `stop()` in the middle of an opening abandons this task
            // and clears the field, and a fresh `start()` may already have put its own there —
            // clearing it blindly would leave that one unreachable, and the next caller would open
            // the room a second time.
            if generation == self.generation { opening = nil }
        }

        try await task.value

        // And the pinned strip back up with the room, if this room ever had one. `stop()` is a
        // pause for both of them, and a pause only one of them woke from would leave the strip at
        // the top of the screen frozen on whatever was pinned when the reader last left.
        //
        // Guarded on the generation like everything else that spans the open: a `stop()` while
        // `open()` was in flight leaves `open()` to bail on its own checks and return normally, and
        // without this the pinned store would then be started for a room nobody is looking at.
        guard generation == self.generation else { return }
        await pinnedStore?.start()
    }

    /// Tries again after a failure. There is nothing to undo first: a `start()` that threw
    /// left `timeline` nil, which is exactly the state it needs to run again from.
    public func retryLoading() async {
        try? await start()
    }

    private func open() async throws {
        // Opening a room we were already in — `stop()` and then `start()` again. The reader is
        // still looking at the conversation from before, and the fresh listener's very first diff
        // is an empty reset, so without this the screen would blank and refill in front of them.
        //
        // It is the same problem `refill()` solves, so it is solved the same way and with the
        // same flag: hold what is on the screen until there is at least as much to replace it
        // with. On a genuinely new room `rows` is empty and none of this does anything.
        let held = rows.count
        let isReopening = held > 0
        isRefilling = isReopening

        // The opening we belong to. Every await below is a chance for the reader to leave the
        // room, and everything after one is a subscription or a field that the *next* opening
        // would then own. See `generation`.
        let generation = self.generation

        if let info = try? await withTimeout(Self.sdkTimeout, operation: { [room] in try await room.roomInfo() }) {
            guard generation == self.generation else { return }
            adopt(info)
        }

        guard generation == self.generation else { return }

        // And then keep it up to date. A room is renamed, somebody pins a message, a person
        // joins — all of that arrives here, and none of it used to: the header and the pinned
        // strip were a snapshot taken when the room was opened and never looked at again.
        roomInfoHandle = room.subscribeToRoomInfoUpdates(listener: RoomInfoUpdates { [weak self] info in
            Task { @MainActor [weak self] in
                self?.adopt(info)
            }
        })

        // Bounded like every other SDK call the reader waits on. `room.timeline()` reads the event
        // store to build the timeline, and a store whose cross-process lock is held by another
        // process — the notification extension, a lingering instance of the app — is a read that
        // can stall. Unbounded, that stall is the whole of `open()` stuck before the first page,
        // `hasLoaded` never set, and a spinner with no way out. A timeout is thrown instead, and
        // `start()` turns it into the "this chat didn't open — try again" screen.
        let timeline = try await withTimeout(Self.sdkTimeout) { [room] in try await room.timeline() }

        // Left while the timeline was being built. The subscription just registered above is not
        // ours to keep — `stop()` has already run and found nothing to cancel — so it is taken
        // down here rather than left feeding a store that has moved on.
        guard generation == self.generation else {
            roomInfoHandle?.cancel()
            roomInfoHandle = nil
            return
        }

        self.timeline = timeline

        // The diffs cross to the main actor down a *queue*, and this is not a detail.
        //
        // Every diff the SDK sends is positional — `insert(at: 3)`, `set(at: 7)`, `remove(at: 2)` —
        // so a batch means nothing except against the exact list the batch before it produced. The
        // listener used to answer each callback with its own `Task { @MainActor }`, and Swift makes
        // *no* ordering promise between separately created unstructured tasks on an actor: they are
        // enqueued, and a later one may run first. When it did, every index in it addressed a list
        // that did not exist yet, and `items` came apart from the timeline the SDK is holding.
        //
        // It came apart *silently*, which is why this survived. The index guards below swallow an
        // out-of-range `set` or `remove` and clamp an out-of-range `insert`, so the first crooked
        // batch neither crashed nor reset anything — it just landed a message in the wrong place
        // and left the array permanently a little wrong, with every later index landing wrong in
        // turn. Paginating is exactly what produces a burst of batches, which is why loading older
        // messages was where the conversation came out shuffled.
        //
        // One stream, one consumer, in the order the SDK spoke. `AsyncStream` buffers without
        // bound and hands its elements over in the order they were yielded, and the loop below is
        // the only thing applying them.
        let (diffs, continuation) = AsyncStream<UnsafeTransfer<[TimelineDiff]>>.makeStream()
        diffContinuation = continuation

        // No `self` in the callback: it runs on a Rust thread, and reaching a main-actor store from
        // there is the very hop this exists to make orderly. The continuation is `Sendable` and is
        // all it needs.
        let listener = ItemsListener { batch in
            continuation.yield(UnsafeTransfer(value: batch))
        }

        // Guarded on the generation, because finishing the stream is not emptying it. `stop()`
        // finishes it and cancels this task, and an `AsyncStream` that has been finished still
        // hands over every batch already buffered — so the old timeline's last diffs arrived after
        // `stop()` had emptied `items`, addressed a list of zero, and tripped `desynced`. It took
        // somebody leaving a room while messages were landing in it; a sent sticker's echo, with
        // the room closed straight after, is what `DemoBackendTests` caught it with.
        diffTask = Task { @MainActor [weak self] in
            for await batch in diffs {
                guard let self, generation == self.generation else { return }
                self.apply(diffs: batch.value)
            }
        }

        listenerHandle = await timeline.addListener(listener: listener)

        // What tells us a reaction never made it. `RoomSendQueueUpdate` is `Sendable` — unlike
        // the timeline's diffs — so it crosses the hop from the Rust callback thread on its own.
        let queueListener = RoomQueueListener { [weak self] update in
            Task { @MainActor [weak self] in
                self?.handle(sendQueueUpdate: update)
            }
        }
        sendQueueHandle = try? await room.subscribeToSendQueueUpdates(listener: queueListener)

        // Who is typing. `[String]` is `Sendable`, so it crosses from the Rust callback thread on
        // its own — no `UnsafeTransfer` needed, unlike the timeline's diffs.
        typingHandle = room.subscribeToTypingNotifications(listener: TypingListener { [weak self] userIDs in
            Task { @MainActor [weak self] in
                await self?.adoptTyping(userIDs)
            }
        })

        // A live timeline starts *empty*, and this is the single most surprising thing
        // about it. Subscribing does not hand over the conversation: the SDK streams new
        // events into the timeline and nothing else, so the first diff a freshly opened
        // room sends is a reset with zero items in it. The messages already in the room are
        // fetched, not streamed — opening a conversation has to go and ask for them.
        //
        // This used to happen by accident. The spinner at the top of the list carried a
        // `.task` that called `loadMore()` the moment it appeared, so the room filled as a
        // side effect of drawing a progress view. Removing that spinner — it span forever
        // and promised work nobody was doing — quietly removed the only thing that was
        // loading any messages, and every chat came up empty. The first page is asked for
        // here now, where it can be seen.
        //
        // Reopening fetches back what the reader had, not one screenful of it — somebody who had
        // scrolled up through a week of conversation and merely looked at the room info should
        // not come back to the live end of it. Same reasoning as `refill()`, same ceiling.
        await fillPages(untilAtLeast: isReopening ? held : Self.screenful,
                        maximumPages: isReopening ? Self.maximumRefillPages : Self.maximumOpeningPages)

        // Fetching the history is the longest await here, and the reader is entitled to leave in
        // the middle of it. Everything below writes what the screen shows.
        guard generation == self.generation else { return }

        if isReopening {
            isRefilling = false
            rows = latestRows
        }

        // A fresh room whose first page could not be fetched at all is a chat that did not open,
        // not an empty one — and "no messages yet" is the wrong, frightening thing to tell someone
        // whose conversation is on the far side of a request that stalled or a network that is gone.
        // So it is escalated to the same failure `start()` already catches, which puts up the
        // "this chat didn't open — try again" screen instead of a false empty room.
        //
        // Guarded so neither of the two legitimately-empty cases is mistaken for it: a reopening is
        // still holding its old rows, and an actually-empty room comes back with `paginateBackwards`
        // having reached the start successfully, so `didFailToPaginate` is false.
        if !isReopening, didFailToPaginate, latestRows.isEmpty {
            throw TimelineOpenError.firstPageUnavailable
        }

        // Only now. Between the empty reset and the first page there is a moment where the
        // room is genuinely empty and genuinely not loaded, and saying "no messages yet"
        // into that gap would be wrong about a conversation that is one await away.
        hasLoaded = true
    }

    /// Why an opening was given up on from inside `open()` itself, rather than by an SDK call
    /// throwing. Thrown so it lands in the same `start()` catch as any other opening failure — and
    /// so `retryLoading()` can run again from the clean state `stop()` leaves.
    private enum TimelineOpenError: Error {
        /// A brand-new room's first page could not be fetched — the store stalled, or the network
        /// is gone and nothing was cached. See `open()`.
        case firstPageUnavailable
    }

    /// Everything the header and the pinned strip read, taken from the room as it now is.
    private func adopt(_ info: RoomInfo) {
        privacy = PrivacyStatus(info.encryptionState)
        serverRoomName = info.serverTitle(besides: ownUserID)
        roomName = info.title(besides: ownUserID)
        kind = info.kind
        isOneToOne = info.isOneToOne
        // The picture falls back to the other person's in a personal chat, exactly as the name
        // above it does — see `RoomInfo.pictureURL`.
        roomAvatarURL = info.pictureURL(besides: ownUserID)
        // And the seed for the stand-in face, from the same place and by the same rule, so the
        // creature in the header is the creature in the chat list rather than a second one.
        roomAvatarSeed = info.avatarSeed(besides: ownUserID)
        roomFaces = info.kind == .group ? info.faces(besides: ownUserID) : []
        memberCount = Int(info.joinedMembersCount)
        pinnedEventIDs = info.pinnedEventIds
        // The heroes are the people the server names to describe a room that has no
        // name of its own — in a DM, that is the person you are talking to. Falling
        // back to nothing (rather than to our own ID) is right: a note-to-self room
        // has no counterpart, and claiming one would put your own address in the
        // header of your own chat.
        directCounterpartID = isOneToOne ? info.counterpart(besides: ownUserID)?.userId : nil

        // Sending is governed by the room's power levels. If the levels are not in the
        // info we just received, leave the previous answer alone: it may have arrived in an
        // earlier update, or it may still be the default. Flipping to "no" only on a clear
        // statement from the room avoids the composer vanishing while the room is still
        // opening.
        if let levels = info.powerLevels {
            canPost = levels.canOwnUserSendMessage(message: .roomMessage)
        }
    }

    /// Asks for history until there is enough of it to scroll.
    ///
    /// Repeatedly, because a page is 25 *events* and events are not messages: a room can
    /// answer with twenty-five joins, avatar changes and topic edits, and hand back a screen
    /// with two bubbles on it. That matters more than it sounds, because scrolling is what
    /// asks for the next page — a conversation too short to scroll could never ask for one,
    /// and would sit there half-loaded forever with no way for the user to pull the rest in.
    ///
    /// It counts `latestRows` rather than `rows`, because during a refill those are not the same
    /// thing: `rows` is the old conversation still held on the screen, and a loop watching it
    /// would never see the new one arrive and would page until it ran out of attempts.
    private func fillPages(untilAtLeast minimumRows: Int, maximumPages: Int) async {
        var fetched = 0
        var waited = 0

        // Two counters, because a turn round this loop is not always a page. `page()` may find one
        // already in flight — put there by the reader scrolling, or by a refill — in which case it
        // waits for that one and comes back having fetched nothing itself. Counting that as an
        // attempt spent the budget on *waiting*: on a slow server a refill could burn all twenty
        // turns without a single request of its own, and then publish the empty conversation it had
        // failed to fetch. That is the exact failure `refill()` exists to prevent, arriving by the
        // back door.
        //
        // The wait still has a ceiling of its own. It should be unreachable — the page we waited on
        // has finished by the time we look again, so the next turn fetches — but a loop whose
        // termination depends on that reasoning being right is a loop that hangs the moment it is
        // not.
        while latestRows.count < minimumRows,
              canLoadMore,
              fetched < maximumPages,
              waited < maximumPages {
            switch await page(showingSpinner: !isRefilling) {
            case .fetched:
                fetched += 1
            case .waited:
                waited += 1
            case .failed:
                // Asking again immediately would only fail again, and four times over it would
                // fail quietly: the loop would end having spent its budget, and the room would
                // settle on however little it had — which is the room that opens with two
                // messages in it. So it stops here and leaves the shortfall *visible*, for
                // `needsMoreHistory` to offer the reader a way out of.
                return
            }
        }
    }

    /// There is more of this conversation, and nothing on the screen can ask for it.
    ///
    /// History is fetched by scrolling to the top — and a room holding two messages cannot be
    /// scrolled. Its content is shorter than the window it sits in, so there is no gesture to
    /// make and no change of geometry for `RoomView` to notice one by. The opening fetch is what
    /// is supposed to prevent that, and there are two ways it does not: a page can *fail*, and
    /// the budget of `maximumOpeningPages` can simply run out in a room whose recent history is
    /// mostly joins and renames. Both end in the same place — a couple of messages on screen,
    /// the rest of the conversation behind them, and nothing left that will ever ask for it.
    ///
    /// So the room says so, and the screen puts a button where the older messages ought to be.
    /// Same rule as the first page: the fetch is an explicit call you can see, never a side
    /// effect of drawing something.
    /// `didFailToPaginate` excluded, because the button is an offer to go and fetch the rest — and
    /// when the last attempt failed, that offer cannot be kept. The room says what is true instead;
    /// see `RoomView.loadEarlier`.
    public var needsMoreHistory: Bool {
        hasLoaded && canLoadMore && !isPaginating && !didFailToPaginate && rows.count < Self.screenful
    }

    /// There is more of this conversation, and we could not reach it. The reader is looking at
    /// everything that was on the device, which offline is the ordinary end of the road: the event
    /// cache goes back as far as it goes, and the page beyond it needs the server.
    ///
    /// Deliberately **not** conditioned on `isPaginating`, and that is not a detail. This decides
    /// whether a row exists at the head of the list, and a row that comes and goes changes the height
    /// of the content — which `RoomView` watches, and answers by asking for another page. So a line
    /// that blinked while a retry ran was not merely ugly: it was a loop, feeding the very scroll
    /// event that started it. It flickered, and the conversation stuttered under the reader's finger.
    public var historyIsStranded: Bool {
        hasLoaded && canLoadMore && didFailToPaginate
    }

    /// The button's call. It asks for a *screenful*, not a page: one press that bought two more
    /// events would leave the reader at the same dead end one page further along.
    public func loadMoreHistory() async {
        // The press *is* permission to try again. Without this the guard in `loadMore` would have
        // grown teeth it was never meant to have: a room whose history failed once could never ask
        // for it again, and the line offering to try would have been a line that did nothing.
        didFailToPaginate = false

        await fillPages(untilAtLeast: rows.count + Self.screenful,
                        maximumPages: Self.maximumOpeningPages)
    }

    /// The network came back, or went away. Told to us by `UserSession`, which hears it from the one
    /// thing in the app that knows — the sync loop. See `RoomListStore.syncStateChanged`.
    ///
    /// A room open at the moment the network returns has to be *let go of*: `loadMore` refuses to
    /// ask for history after a page has failed, and offline every page fails, so without this the
    /// conversation the reader is sitting in would stay stranded at the edge of its cache for as
    /// long as it stayed open — with the network back, the banner gone, and nothing to explain why
    /// scrolling up did nothing at all.
    func connectivityChanged(offline: Bool) async {
        guard !offline, didFailToPaginate else { return }

        didFailToPaginate = false

        // And go and get what the reader was denied while the network was away, rather than waiting
        // for them to scroll again to find out that they may now.
        await fillPages(untilAtLeast: max(rows.count, Self.screenful),
                        maximumPages: Self.maximumRefillPages)
    }

    /// Roughly what fills a phone screen. Not exact, and does not need to be: it is the
    /// point past which the user can scroll, and scrolling is what fetches the rest.
    private static let screenful = 15

    /// A ceiling on the opening fetch, so a room whose history is nothing but membership
    /// churn cannot spin here forever looking for fifteen bubbles it will never find.
    private static let maximumOpeningPages = 4

    /// The same ceiling for a refill, and higher, because a refill is trying to win back
    /// everything the reader had already scrolled through rather than just a first screenful.
    private static let maximumRefillPages = 20

    /// The ceiling on a single SDK call the reader waits on while a room opens — the store read that
    /// builds the timeline, the room-info read, and each paginate that reaches the network. It is
    /// the timeline's share of the app-wide invariant that *every* call the user waits on is bounded
    /// (see `withTimeout`): without it, a store lock held by another process or a server that
    /// accepts a request and never answers leaves the room on a spinner with no way out. Generous,
    /// because a slow network is not a failure — finite, because a stalled one must not be forever.
    private static let sdkTimeout: Duration = .seconds(30)

    /// Puts the room down. `start()` picks it up again.
    ///
    /// It is a *pause*, and it did not used to be one: it cancelled every handle and then left
    /// `timeline` set — while `start()` opens with `guard timeline == nil else { return }`. So a
    /// store that had been stopped could never be started again. It sat there with no listener
    /// subscribed and a timeline it would not replace, `rows` frozen at whatever was last in
    /// them, no new message ever arriving, and no way back short of leaving the room. Anything
    /// that stopped a room it meant to come back to — pushing a screen over it, backgrounding
    /// the app — killed the conversation quietly and for good.
    ///
    /// So everything the SDK owns goes, and `timeline` goes with it. `rows` deliberately stay:
    /// they are what the reader is looking at, and `open()` holds them on the screen while it
    /// fetches the conversation back. See the reopening path there.
    public func stop() {
        // Everything already in flight belongs to the room we are leaving, and none of it may
        // write into the room we open next. Cancelling a `Task` does not reach one that is sitting
        // in an await inside the SDK; the number does. See `generation`.
        generation += 1
        opening = nil

        // Putting the room down is leaving it — for the info screen, for the pocket, for another
        // room — and leaving is when the bar moves. See `hasReadToEnd`.
        moveReadMarkerIfRead()

        // The second timeline over this room goes down with the first. Nothing else was ever going
        // to do it: the pinned store is handed to a view, and a view has no idea that the account
        // it belongs to is being signed out from three screens away.
        pinnedStore?.stop()

        pageInFlight?.cancel()
        pageInFlight = nil

        refillTask?.cancel()
        refillTask = nil
        listenerHandle?.cancel()
        listenerHandle = nil

        // The queue the diffs came down, and the one task that was draining it. Finished before
        // `items` is emptied below, so nothing can apply a diff from the timeline that is going
        // to the list that replaces it.
        diffContinuation?.finish()
        diffContinuation = nil
        diffTask?.cancel()
        diffTask = nil
        sendQueueHandle?.cancel()
        sendQueueHandle = nil
        roomInfoHandle?.cancel()
        roomInfoHandle = nil

        typingHandle?.cancel()
        typingHandle = nil

        // And we stop saying that *we* are typing. Walking out of a room mid-word must not leave
        // the other person watching a notice that will never be withdrawn.
        typingStopper?.cancel()
        typingStopper = nil
        if isTellingThemWeType {
            isTellingThemWeType = false
            let room = room
            Task { try? await room.typingNotice(isTyping: false) }
        }
        typing = []

        timeline = nil
        // The SDK's items belong to the timeline that has just gone. A fresh listener opens with
        // an empty reset and repopulates from scratch, and leaving the old ones here would have
        // the next `apply` computing diffs against a timeline that no longer exists.
        items = []

        // And the rows those items made. `rows` deliberately stay — they are what the reader is
        // looking at, and `open()` holds them on the screen while it fetches the conversation
        // back — but `latestRows` is a different thing wearing the same shape: it is the *measure*
        // `fillPages` works towards. Left at the depth of the room we have just put down, it says
        // the reopening is already as deep as it needs to be, `fillPages` does not turn its loop
        // even once, and the room comes back holding whatever the fresh listener's first reset
        // happens to carry — the live tail, which is one message. That is the "sometimes a chat
        // reopens with only the last message in it" this pair of lines closes; the other half of
        // it is the stale page handle described in `page(showingSpinner:)`.
        latestRows = []

        // `canLoadMore` is a statement about the timeline we hold, and we are no longer holding
        // one. Left false — which is what it is in every room that has been read back to its
        // beginning — it stops the reopening fetch before it asks for anything at all: `fillPages`
        // tests it on the way into the loop and `page()` refuses outright. `refill()` resets it
        // for precisely this reason, and putting the room down throws the timeline away just as
        // thoroughly as the event cache does.
        canLoadMore = true

        // What we had sent and were still waiting to see. The stand-in bubbles belong to the
        // timeline that has gone, and the message itself is safe in the SDK's send queue — it
        // comes back as an ordinary echo when the room opens again. See `PendingSends`.
        pending.removeAll()

        // And what we had asked about them. See `askedForReplyDetails`.
        askedForReplyDetails.removeAll()

        isPaginating = false
        isRefilling = false
    }

    // MARK: - Sending

    /// Sends a plain text message. Markdown is honoured, because people type `*this*`
    /// and expect it to work.
    ///
    /// `replyingTo` is a *message* ID, which is what the rest of the app deals in. It is only
    /// ever an answer to something the server already has: `sendReply` names an event, and a
    /// message still in our own send queue does not have one. A reply to something unsendable
    /// is sent as an ordinary message rather than refused — the user wrote words and pressed
    /// send, and swallowing them to protect a quote would be the app losing their message over
    /// a decoration.
    public func send(text: String, replyingTo replyID: String? = nil) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // An empty box is nothing to send and nothing to report. A room with no timeline is a
        // *failure* to send, and the user pressed the button — see `TimelineStore+Media`, where the
        // same silent return swallowed photographs.
        guard !trimmed.isEmpty else { return }

        guard let timeline else {
            Log.media.error("nothing was sent: the room has no live timeline")
            failure = .send
            return
        }

        // The words go on the screen *first*, and the sending happens behind them.
        //
        // The SDK does echo a sent message back into the timeline almost at once — that is what
        // normally puts the bubble there, with a clock beside it — but "almost" was a few hundred
        // milliseconds, and the user spends every one of them looking at a composer they have
        // already emptied and a conversation that has not changed. The app appears to have
        // swallowed what they wrote. So the bubble is ours until the real one arrives; see
        // `PendingSends`, which also explains how the two are told apart.
        let shown = Set(rows.compactMap { $0.message?.isOwn == true ? $0.message?.id : nil })
        let pendingID = pending.add(text: trimmed, replyingTo: replyID, alreadyShown: shown)
        rebuildRows()
        forgetPending(pendingID, after: PendingSends.lifetime)

        // Sending is the end of writing. Waiting for the four-second lull to notice would leave
        // the other person watching "typing…" for four seconds *after* the message had landed in
        // front of them, which is the one moment it is obviously untrue.
        //
        // Not *awaited*, and that is the whole of where the delay went. `typingNotice` is a
        // request to the homeserver like any other, and this one stood between the press and the
        // message even reaching the send queue: on a slow network the bubble waited out a round
        // trip whose only purpose was to stop a "typing…" nobody would have seen again anyway.
        // Withdrawing the notice is still the right thing to do and still done at once — it is
        // simply not something the message has to queue behind.
        stopTellingThemWeType()

        // Not logged, not stored anywhere but the SDK's encrypted send queue.
        let content = messageEventContentFromMarkdown(md: trimmed)

        do {
            if let replyID, let eventID = eventID(for: replyID) {
                try await timeline.sendReply(msg: content, eventId: eventID)
            } else {
                _ = try await timeline.send(msg: content)
            }
        } catch {
            // The SDK would not even take it, so there is no echo coming and nothing in the queue:
            // the stand-in is all there is, and leaving it would be a bubble claiming to be on its
            // way to a room it never left. It goes, and the failure is reported instead.
            pending.remove(id: pendingID)
            rebuildRows()
            failure = .send
        }
    }

    /// Sends a sticker from a pack — see `Sticker`.
    ///
    /// `Room.sendRaw` and not the timeline, because the timeline has no call for it: it sends
    /// messages, attachments, locations and polls, and an `m.sticker` is none of those. Raw is
    /// still encrypted in an encrypted room — the SDK seals any event type the same way — and
    /// nothing is uploaded, because the picture is already on the server and the event only points
    /// at it.
    ///
    /// What raw does *not* get is the send queue, and the difference shows in one place: offline.
    /// A typed message waits on disk for the network; a sticker is refused at once and the failure
    /// is said. Pretending it was queued would be a sticker that silently never arrives.
    public func send(sticker: Sticker, replyingTo replyID: String? = nil) async {
        let eventID = replyID.flatMap { eventID(for: $0) }
        let content = sticker.eventContent(replyingTo: eventID)

        guard let data = try? JSONSerialization.data(withJSONObject: content) else {
            failure = .sticker
            return
        }
        guard let json = String(bytes: data, encoding: .utf8) else {
            failure = .sticker
            return
        }

        stopTellingThemWeType()

        do {
            let room = room
            try await withTimeout(Self.sdkTimeout) {
                try await room.sendRaw(eventType: "m.sticker", content: json)
            }
        } catch {
            Log.media.error("could not send a sticker: \(Log.describe(error), privacy: .public)")
            failure = .sticker
        }
    }

    /// Gives up on a stand-in that nothing ever came to replace.
    ///
    /// Nothing is said about it and nothing is lost: the message is in the SDK's encrypted send
    /// queue, which is what actually guarantees it goes, and it will appear as an ordinary bubble
    /// the moment the timeline catches up with it. This only stops a row that exists to cover a
    /// few hundred milliseconds from sitting in the conversation for the rest of the session if
    /// the echo we were matching on never looked the way we expected.
    private func forgetPending(_ id: String, after delay: Duration) {
        let generation = self.generation

        Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)

            guard let self, generation == self.generation,
                  self.pending.all.contains(where: { $0.id == id }) else { return }

            self.pending.remove(id: id)
            self.rebuildRows()
        }
    }

    /// Changes what a message says, for everyone.
    ///
    /// Matrix does not rewrite the original — it cannot, events are immutable — it sends a new
    /// event that *replaces* it, and every client that understands the relation shows the new
    /// words with an "edited" mark beside them. One that does not understand it shows both.
    /// That is the protocol's business and not ours; what matters here is that the old text
    /// does not disappear from the server, so an edit is not a way to unsay something. Deleting
    /// is.
    ///
    /// Empty is refused rather than sent. An edit to nothing would leave a bubble with no words
    /// in it, which is neither a message nor a deletion — the user who wants the message gone
    /// wants `delete`.
    public func edit(messageID: String, text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let timeline, let id = eventOrTransactionID(for: messageID) else { return }

        do {
            let content = messageEventContentFromMarkdown(md: trimmed)
            try await timeline.edit(eventOrTransactionId: id, newContent: .roomMessage(content: content))
        } catch {
            failure = .edit
        }
    }

    /// Sends one stuck message again.
    ///
    /// A failure jams things in one of two ways, and the user cannot tell them apart: either
    /// the SDK paused the whole room's send queue, or it parked this single message and left
    /// the queue running. So both are undone. Re-enabling an already-enabled queue does
    /// nothing, and `tryResend` is exactly what the SDK provides for a parked message whose
    /// obstacle has since been cleared — a device that has now been verified, a server that
    /// has stopped saying no.
    ///
    /// Nothing here composes or re-sends content of its own: it is the message the user
    /// already wrote, still sitting in the encrypted send queue where they left it.
    public func retrySending(messageID: String) async {
        room.enableSendQueue(enable: true)
        requeueUnsentReactions()

        guard let handle = sendHandle(for: messageID) else { return }
        try? await handle.tryResend()
    }

    /// Restarting the send queue sends everything in it, and that includes the reactions.
    ///
    /// This is the other half of `reactionsDidFail`, and it was missing, which made that one a
    /// trap door. The queue is FIFO and stops dead on an error, so a *message* that fails strands
    /// every reaction queued behind it — `reactionsDidFail` marks them unsent and takes the pills
    /// off the screen, correctly. But `enableSendQueue(enable: true)` then restarts the queue and
    /// **all of it goes out**, the reactions with it. Nothing put them back.
    ///
    /// So: user is offline, reacts 👍, sends a message, the message fails, the 👍 pill vanishes.
    /// They press "Send again". The message goes. The 👍 goes with it — it is on the server, and
    /// everyone else in the room can see it. And `unsentReactions` still holds it, so `applied(to:)`
    /// goes on subtracting it from every rebuild for the life of the store: the user is the one
    /// person who cannot see their own reaction, and where two others also pressed 👍 their pill
    /// reads "👍 2" while every other client in the room reads "👍 3".
    ///
    /// They are not unsent now; they are in flight. So they go back to being watched, exactly as
    /// a fresh reaction is — and if the queue errors again, `reactionsDidFail` will mark them
    /// unsent again, which is the truth twice over rather than once.
    private func requeueUnsentReactions() {
        guard !unsentReactions.isEmpty else { return }

        for reaction in unsentReactions.all {
            let inFlight = InFlightReaction(messageID: reaction.messageID, key: reaction.key)
            reactionsInFlight.append(inFlight)
            stopWatching(inFlight, after: Self.reactionSendWindow)
        }

        unsentReactions.removeAll()
        rebuildRows()
    }

    /// Throws away a message that never went.
    ///
    /// The way out of the two dead ends the red badge otherwise leaves the user in: a
    /// failure nothing will ever clear — a file that has been deleted, a type the server
    /// will never accept — and a message they have simply changed their mind about. Both
    /// used to be permanent, because a stuck message sits in the send queue and is retried
    /// on every launch.
    ///
    /// Nothing is redacted and nobody is told: the message is still in the encrypted send
    /// queue and has reached no one, so there is no event on the server to take back.
    /// `abort()` lifts it out of the queue, the SDK drops the local echo, and the bubble
    /// goes with it.
    ///
    /// No confirmation, unlike `delete()`. That one is irreversible *for the whole room*;
    /// this one only ever touches a message the user is looking at because they opened the
    /// badge to ask about it, and making them confirm twice to be rid of something they
    /// never managed to send would be the app arguing with them.
    ///
    /// `abort()` answers false if the message went out while the popover was open — it is
    /// an ordinary sent message now, so there is nothing here to abort and nothing to do:
    /// the badge disappears of its own accord, and `delete()` becomes the way to take it
    /// back, offered by the menu the moment `canDelete` turns true.
    public func discard(messageID: String) async {
        guard let handle = sendHandle(for: messageID) else { return }
        _ = try? await handle.abort()
    }

    /// Sends a message the queue stopped on because somebody the user verified no longer checks
    /// out — having been told so, and having said "send it anyway".
    ///
    /// The two ways the SDK offers, one per reason, and each is a real change of trust rather than
    /// a retry: `withdrawVerificationAndResend` takes back the verification of the people whose
    /// keys changed (they become merely known, as everybody unverified is), and
    /// `ignoreDeviceTrustAndResend` trusts the devices their owner never confirmed. Both then send
    /// the message that was waiting. Throws when the SDK refuses, so the screen can say so.
    public func sendAnyway(messageID: String) async throws {
        guard let (handle, wedge) = failedSend(for: messageID) else { return }
        room.enableSendQueue(enable: true)
        requeueUnsentReactions()
        switch wedge {
        case let .identityViolations(users):
            try await room.withdrawVerificationAndResend(userIds: users, sendHandle: handle)
        case let .insecureDevices(devices):
            try await room.ignoreDeviceTrustAndResend(devices: devices, sendHandle: handle)
        default:
            try await handle.tryResend()
        }
    }

    /// The handle and the SDK's own reason for a message stuck in the queue — the reason with
    /// the people and devices in it, which `SendFailure` leaves out because a reader of the chat
    /// has no use for a list of device IDs.
    private func failedSend(for messageID: String) -> (SendHandle, QueueWedgeError)? {
        for item in items {
            guard let event = item.asEvent(),
                  TimelineMapper.identifier(for: event.eventOrTransactionId) == messageID,
                  case let .sendingFailed(error, _) = event.localSendState,
                  let handle = event.lazyProvider.getSendHandle() else { continue }
            return (handle, error)
        }
        return nil
    }

    /// The SDK's handle on a local echo — the message we sent that never landed. Remote
    /// events have none, which is the SDK's way of saying there is nothing left to retry.
    private func sendHandle(for messageID: String) -> SendHandle? {
        for item in items {
            guard let event = item.asEvent(),
                  TimelineMapper.identifier(for: event.eventOrTransactionId) == messageID else { continue }
            return event.lazyProvider.getSendHandle()
        }
        return nil
    }

    // MARK: - Reacting and unsending

    /// Everybody who reacted to a message, named the way this room names them — the list a group's
    /// message menu opens. Emoji in the order they first appeared, people in the order they pressed.
    ///
    /// Asked for when the list is opened, not kept on every message: a name costs a lookup in the
    /// room's member list, and a pill only ever needs a count.
    public func reactors(of messageID: String) async -> [Reactor] {
        let message = rows.lazy.compactMap(\.message).first { $0.id == messageID }
        guard let message else { return [] }

        var names: [String: (String, String?)] = [:]
        var reactors: [Reactor] = []
        for reaction in message.reactions {
            for userID in reaction.senders {
                if names[userID] == nil {
                    let name = (try? await room.memberDisplayName(userId: userID))
                    let avatar = (try? await room.memberAvatarUrl(userId: userID))
                    names[userID] = (name ?? userID, avatar)
                }
                let (name, avatar) = names[userID] ?? (userID, nil)
                reactors.append(Reactor(key: reaction.key, userID: userID, name: name, avatarURL: avatar))
            }
        }
        return reactors
    }

    /// Adds an emoji to a message, or takes it back if it is already ours.
    ///
    /// One call for both directions, because that is what the SDK offers and what the UI
    /// wants: a reaction pill is a toggle, and the user pressing one they have already
    /// left plainly means "undo".
    ///
    /// The pill lights up the moment it is pressed, and that is the SDK's doing, not ours: the
    /// reaction goes into the same encrypted send queue as a message and is echoed into the
    /// timeline straight away. **The echo is not proof of anything.** `toggleReaction` returns
    /// as soon as the reaction is *queued*, so the `try` here catches a reaction the SDK would
    /// not even take — not one the server never saw. When the send itself fails, the Rust
    /// timeline keeps the echo exactly where it is, and the pill stays lit on a reaction that
    /// reached nobody. That is what `unsentReactions` exists to undo.
    ///
    /// Only an *added* reaction is watched. A removal that fails leaves the pill on the screen
    /// where it always was, which is the truth — the reaction is still on the server.
    public func toggleReaction(messageID: String, key: String) async {
        guard let timeline, let id = eventOrTransactionID(for: messageID) else { return }

        // A reaction on a message that is gone is one Matrix would accept and nobody wants: an
        // emoji hanging under the words "message deleted", for the whole room. The menu does not
        // offer it and a double tap does not send it, but both of those are views, and this is
        // the one call that actually leaves the device — so the rule is kept here as well.
        guard message(messageID)?.canReact == true else { return }

        // Pressing a pill we took away is the user saying "try again". The queue stopped when it
        // failed — it stays disabled until something re-enables it — so start it back up before
        // handing it anything, exactly as `retrySending` does for a stuck message.
        let isRetry = unsentReactions.contains(messageID: messageID, key: key)
        if isRetry {
            room.enableSendQueue(enable: true)
            unsentReactions.remove(messageID: messageID, key: key)
            rebuildRows()
        }

        // Registered *before* the call, not after: the queue can fail while we are still in
        // `toggleReaction`, and a failure that arrives before we start watching is a failure
        // nobody would ever hear about.
        let reaction = InFlightReaction(messageID: messageID, key: key)
        reactionsInFlight.append(reaction)
        stopWatching(reaction, after: Self.reactionSendWindow)

        do {
            var wasAdded = try await timeline.toggleReaction(itemId: id, key: key)

            // The reaction that failed is still sitting in the SDK's queue, and the SDK still
            // counts it as ours — so it read this press as "undo" and cancelled the stuck one.
            // That is not what the user meant. To them the pill was gone, and they are putting
            // it back. Losing the stuck reaction is no loss at all, but the one they actually
            // asked for still has to be sent, so ask again.
            if isRetry, !wasAdded {
                wasAdded = try await timeline.toggleReaction(itemId: id, key: key)
            }

            if !wasAdded { forget(reaction) }
        } catch {
            forget(reaction)
            failure = .reaction
        }
    }

    /// A reaction the send queue has taken and not yet answered for.
    private struct InFlightReaction: Identifiable {
        let id = UUID()
        let messageID: String
        let key: String
    }

    /// Everything the send queue has to say about this room. The only part that concerns a
    /// reaction is a failure.
    ///
    /// It is deliberately not asked *which* request failed, and it could not usefully answer.
    /// A reaction to a message that has not been sent yet is a "dependent request", and those
    /// report neither success nor failure over FFI; the transaction ID on a `sendError` belongs
    /// to whatever the queue choked on, which may well be somebody's message. It does not
    /// matter. A send error stops the room's queue dead, and the queue is first-in-first-out —
    /// so whatever the error was about, a reaction still waiting behind it is going nowhere.
    ///
    /// Except a *recoverable* one. That is the queue pausing on a failure that may pass — the
    /// network, a server timing out — and it is started again by itself (`SendQueueRecovery`), the
    /// reactions behind it with it. Taking the pills off then would be wrong twice: the reaction is
    /// on its way, and when it lands the pill would stay hidden, subtracted by `unsentReactions`
    /// from a reaction everybody else in the room can see. Like a message, it waits with the queue.
    private func handle(sendQueueUpdate update: RoomSendQueueUpdate) {
        guard case .sendError(_, _, isRecoverable: false) = update else { return }
        reactionsDidFail()
    }

    private func reactionsDidFail() {
        guard !reactionsInFlight.isEmpty else { return }

        for reaction in reactionsInFlight {
            unsentReactions.insert(messageID: reaction.messageID, key: reaction.key)
        }
        reactionsInFlight.removeAll()

        // The pills go out, and the user is told why. Both: a pill quietly vanishing under the
        // thumb that just pressed it looks like the app dropped the tap.
        rebuildRows()
        failure = .reaction
    }

    private func forget(_ reaction: InFlightReaction) {
        reactionsInFlight.removeAll { $0.id == reaction.id }
    }

    /// Stops holding a reaction responsible for a failure that has not happened yet.
    ///
    /// There is no success to wait for. The SDK never says a reaction landed — no update, no
    /// status on the pill, nothing — so "it worked" can only ever be inferred from the absence
    /// of the failure, and the inference has to be given a deadline or it never completes.
    /// A reaction the queue has held without complaint for this long has been sent, and a queue
    /// error after that belongs to whatever the user did next, not to this.
    ///
    /// Erring towards forgetting, deliberately. Watching a reaction too long risks pulling a
    /// pill off a reaction that is really on the server, and telling the user their reaction
    /// failed when it did not; forgetting one too early only means a rare stuck reaction stays
    /// lit, which is where every one of them stood before this existed.
    private func stopWatching(_ reaction: InFlightReaction, after seconds: Int) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            self?.forget(reaction)
        }
    }

    /// How long a reaction is watched for. Generous: it covers a slow send behind a media
    /// upload, and its only cost is a wider window in which a failure is blamed on a reaction
    /// that had in fact gone out.
    private static let reactionSendWindow = 30

    /// Takes a message back for everyone.
    ///
    /// No reason is given: Matrix lets a redaction carry one, it is visible to the whole
    /// room, and nothing in this app asks the user for it — sending an empty or invented
    /// string would be putting words in their mouth.
    public func delete(messageID: String) async {
        guard let timeline, let id = eventOrTransactionID(for: messageID) else { return }

        do {
            try await timeline.redactEvent(eventOrTransactionId: id, reason: nil)
        } catch {
            failure = .delete
        }
    }

    // MARK: - Pinning

    /// The messages the room has pinned, newest last, as the room itself reports them.
    ///
    /// Kept in step by a subscription rather than re-read after every pin: somebody *else*
    /// pinning a message has to move the banner at the top of the conversation too, and a
    /// value we only refresh when we act would leave every other client's pin invisible until
    /// the app was restarted.
    public private(set) var pinnedEventIDs: [String] = []

    /// Whether a message is currently pinned, which is what decides between the two words the
    /// menu can offer.
    public func isPinned(messageID: String) -> Bool {
        pinnedEventIDs.contains(messageID)
    }

    /// Pins a message to the top of the room. Everyone sees it; it is a change to the room's
    /// state, not a note to self.
    public func pin(messageID: String) async {
        guard let timeline, let eventID = eventID(for: messageID) else { return }

        do {
            _ = try await timeline.pinEvent(eventId: eventID)
        } catch {
            failure = .pin
        }
    }

    public func unpin(messageID: String) async {
        guard let timeline, let eventID = eventID(for: messageID) else { return }

        do {
            _ = try await timeline.unpinEvent(eventId: eventID)
        } catch {
            failure = .pin
        }
    }

    // MARK: - Reporting

    /// Reports a message to the room's moderators and the homeserver. The reason is the user's own
    /// words — Matrix carries a free-text reason on a report, and unlike a redaction (which we send
    /// without one, so as not to put words in anyone's mouth) a report is *addressed to a human*, and
    /// the sentence is what they act on.
    ///
    /// Only a message that has actually reached the server can be reported — a report points at an
    /// event ID, and one still in the send queue has none. `eventID(for:)` returns nil for those, and
    /// the guard drops the attempt rather than reporting the wrong thing.
    public func report(messageID: String, reason: String) async {
        guard let eventID = eventID(for: messageID) else { return }

        do {
            try await room.reportContent(eventId: eventID, reason: reason.isEmpty ? nil : reason)
        } catch {
            failure = .report
        }
    }

    // MARK: - Searching within the room

    /// A store for searching just this conversation, built from the room this timeline already
    /// holds — so the search screen does not have to go back to the session for a handle it is
    /// standing next to. See `RoomSearchStore`.
    public func makeSearch() -> RoomSearchStore {
        RoomSearchStore(room: room)
    }

    // MARK: - Forwarding

    /// Sends a message from another room into *this* one. Matrix has no native forward, so a forward
    /// is a new message that happens to carry the same thing — which for media means re-sending it
    /// through the encrypting attachment path, never copying the source URL: `uploadMedia` does not
    /// encrypt, and copying a `MediaSource` across rooms would hand the destination room's members an
    /// attachment their keys cannot open (or, worse, one uploaded in the clear). The bytes are fetched
    /// with `loader` and sent again, so the destination room's own encryption applies.
    ///
    /// Text-shaped messages carry their words; pictures, videos and files carry their bytes. A voice
    /// note, a video note, a location or a sticker is not forwarded — each would need re-deriving its
    /// own metadata, and forwarding one is not a thing anyone asks for. Those return without sending.
    public func forward(_ message: Message, loader: MediaLoader) async {
        switch message.kind {
        case let .text(body), let .notice(body), let .emote(body):
            await send(text: body)

        case let .image(attachment):
            guard let data = try? await loader.data(for: attachment) else { failure = .send; return }
            await send(photo: data, filename: attachment.filename)

        case let .video(attachment):
            // The `MediaFile` is held across the send: let go of it and the SDK deletes the decrypted
            // bytes from disk, which the upload is still reading.
            guard let file = try? await loader.file(for: attachment) else { failure = .send; return }
            await send(video: file.url)
            withExtendedLifetime(file) {}

        case let .file(attachment):
            guard let file = try? await loader.file(for: attachment) else { failure = .send; return }
            await send(file: file.url)
            withExtendedLifetime(file) {}

        default:
            // Voice, video note, location, sticker, and anything gone or unsendable. Nothing sent.
            break
        }
    }

    /// Everything the room has pinned, as its own conversation — for the "Pinned" screen, and
    /// for the strip above the room that shows the latest of them.
    ///
    /// A second timeline over the same room, which the SDK supports directly: a
    /// `TimelineFocus.pinnedEvents` timeline holds exactly the pinned events and follows them
    /// as they change. It is built on demand, because most rooms have nothing pinned and an
    /// unopened one costs nothing.
    ///
    /// Held once made, and that is the fix rather than the convenience. This used to hand back a
    /// *new* store on every call, owned by whoever asked and stopped by nobody — `PinnedStore.stop`
    /// had no callers at all. Its listener therefore outlived the room, and outlived the sign-out:
    /// `logout()` deletes the SQLite store off the disk, and a live `addListener` on a pinned
    /// timeline was still pointed at it. Now the timeline that made it takes it down with itself,
    /// and brings it back up in `start()` — see both.
    public func pinned() -> PinnedStore {
        if let pinnedStore { return pinnedStore }

        let store = PinnedStore(room: room, ownUserID: ownUserID)
        pinnedStore = store
        return store
    }

    // MARK: - Identifiers

    /// The SDK's name for a message, which is an event ID once the server has seen it and
    /// a local transaction ID before that. `Message.id` is one or the other flattened to a
    /// string, so this walks back from it to the pair the SDK actually wants.
    private func eventOrTransactionID(for messageID: String) -> EventOrTransactionId? {
        for item in items {
            guard let event = item.asEvent(),
                  TimelineMapper.identifier(for: event.eventOrTransactionId) == messageID else { continue }
            return event.eventOrTransactionId
        }
        return nil
    }

    /// The message's event ID, and nil for one the server has never seen.
    ///
    /// Replying to a message and pinning one both name an *event*, and a message still sitting
    /// in the send queue is a transaction ID with nothing on the server behind it. Nil is the
    /// honest answer, and every caller here treats it as one.
    ///
    /// Not private: attachments reply too, and they are sent from `TimelineStore+Media`.
    func eventID(for messageID: String) -> String? {
        guard case let .eventId(eventID)? = eventOrTransactionID(for: messageID) else { return nil }
        return eventID
    }

    /// The message a row is showing, as the rest of the app knows it — with `canReact` and
    /// `canDelete` already worked out on it, so those rules are asked rather than restated.
    /// The message as it *is*, not as the screen is currently drawing it.
    ///
    /// `latestRows`, not `rows`, and the difference is the whole reason this note exists. During a
    /// refill `rows` is deliberately the conversation from a moment ago — that is what stops the
    /// screen blinking empty while the history is fetched back (see `rebuildRows()`). It is a
    /// *picture*, and asking a picture whether a message can still be reacted to is asking the wrong
    /// thing: `toggleReaction` consults `canReact` before making the one call in this file that
    /// leaves the device, and a message deleted while the refill was in flight is still standing in
    /// `rows`, still answering yes. The reaction goes to the server and hangs under the words
    /// "message deleted", for the whole room to see.
    private func message(_ id: String) -> Message? {
        for row in latestRows {
            guard case let .message(message) = row, message.id == id else { continue }
            return message
        }
        return nil
    }

    /// Tells the server the user has seen the conversation, which is what clears the
    /// badge here and shows a read tick on the sender's side.
    ///
    /// Two calls, because the SDK's `markAsRead` says so in as many words: it attaches a receipt
    /// to the latest event and *"does NOT unset the unread flag; it's the caller's
    /// responsibility"*. The flag is the one a person sets by hand from the room list, and it
    /// outlives being read — so a room marked unread on purpose, then opened and read to the
    /// bottom, went on wearing its badge with nothing in it left to read.
    public func markAsRead() async {
        hasReadToEnd = true
        try? await room.markAsRead(receiptType: .read)
        try? await room.setUnreadFlag(newValue: false)
    }

    /// Whether the reader got to the end of the conversation while it was open, which is what
    /// moves the "Unread messages" bar — on the way *out*. See `TimelineRow.unreadDivider`.
    ///
    /// Two markers, and they are not the same thing. The read receipt (`.read`) tells the others
    /// how far you have got, and goes the moment you have got there. The fully-read marker
    /// (`.fullyRead`) is the account's own note of where to put the bar next time — and if it moved
    /// the moment you reached the end, the SDK would take the bar away under the reader's eyes, and
    /// the conversation would jump by its height while they were reading what it pointed at.
    /// Telegram keeps the bar for the whole visit and drops it on the next one. So does this.
    private var hasReadToEnd = false

    /// The reader is leaving having read it all: the bar goes to the end, for next time.
    private func moveReadMarkerIfRead() {
        guard hasReadToEnd else { return }
        hasReadToEnd = false
        let room = room
        Task { try? await room.markAsRead(receiptType: .fullyRead) }
    }

    // MARK: - Drafts

    /// Half a sentence, kept for when you come back to it.
    ///
    /// Through the SDK rather than through `UserDefaults`, and that is a security decision before
    /// it is a convenience one. A draft is a message — the user's own words, not yet sent, often
    /// the most considered thing they will write all day — and a plist in the App Group container
    /// is plaintext on disk. The SDK keeps it in the same passphrase-encrypted SQLite store as the
    /// conversation it belongs to, which is where a message belongs. Nothing in this app writes
    /// message content anywhere else, and a draft is not an exception to that rule.
    ///
    /// `threadRoot: nil` throughout: this app has no threads, and a draft in the room is a draft in
    /// the room.
    public func draft() async -> String? {
        // Two ways to have no draft, and they flatten to the same answer: the call threw, or the
        // room simply has none.
        guard let draft = (try? await room.loadComposerDraft(threadRoot: nil)) else {
            return nil
        }
        return draft.plainText
    }

    public func saveDraft(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // An empty draft is not a draft, it is the absence of one — and saving the empty string
        // rather than clearing it would leave every room the user has ever glanced into holding a
        // draft of nothing, which is the sort of thing that quietly makes a store grow forever.
        guard !trimmed.isEmpty else {
            try? await room.clearComposerDraft(threadRoot: nil)
            return
        }

        let draft = ComposerDraft(plainText: text,
                                  htmlText: nil,
                                  draftType: .newMessage,
                                  attachments: [])
        try? await room.saveComposerDraft(draft: draft, threadRoot: nil)
    }

    /// The message went. There is nothing left to come back to.
    public func clearDraft() async {
        try? await room.clearComposerDraft(threadRoot: nil)
    }

    // MARK: - Typing

    /// Turns the Matrix IDs the server sends into the names the room knows people by.
    ///
    /// Ourselves removed first, and that is not a nicety: the server echoes our own typing notice
    /// back to us along with everybody else's, so without this the header would tell the user that
    /// they are typing — which they can see, and which would be the app talking to itself.
    private func adoptTyping(_ userIDs: [String]) async {
        var names: [String] = []

        for userID in userIDs where userID != ownUserID {
            // The name they are known by *in this room*, which is not always the name they are
            // known by elsewhere. The Matrix ID is what is left when they have chosen none.
            let name = (try? await room.memberDisplayName(userId: userID))
            names.append(name ?? userID)
        }

        typing = names
    }

    /// Says that the user is writing something — and, a moment later, that they have stopped.
    ///
    /// Called on every keystroke, and deliberately cheap about it: a typing notice is an HTTP
    /// request, and one per character would be a flood. So the *first* keystroke tells the server
    /// and the rest do nothing but push back the moment we take it back.
    ///
    /// Taking it back matters more than sending it. A notice the server is never told to withdraw
    /// leaves the other person watching "Аня печатает…" for as long as the server's own timeout —
    /// while Аня has put her phone down mid-word and gone to lunch.
    public func typed() {
        // Hidden in Settings → Privacy: nothing is sent, and so there is nothing to take back.
        guard !PrivacySettings.hidesTyping() else { return }
        typingStopper?.cancel()

        if !isTellingThemWeType {
            isTellingThemWeType = true
            Task { try? await room.typingNotice(isTyping: true) }
        }

        typingStopper = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.typingLull))
            guard !Task.isCancelled else { return }
            await self?.stoppedTyping()
        }
    }

    /// The same withdrawal, not waited for — the one the *sending* path uses.
    ///
    /// It exists rather than being folded into `stoppedTyping()` because the difference is the
    /// point: leaving the composer can afford to wait for the server to be told, and pressing
    /// send cannot. Everything before the request is done here and now, so a second press cannot
    /// send a second notice; only the round trip is let go of.
    private func stopTellingThemWeType() {
        typingStopper?.cancel()
        typingStopper = nil

        guard isTellingThemWeType else { return }
        isTellingThemWeType = false

        let room = room
        Task { try? await room.typingNotice(isTyping: false) }
    }

    /// Withdraws the notice at once — the message has been sent, or the composer has been left.
    public func stoppedTyping() async {
        typingStopper?.cancel()
        typingStopper = nil

        guard isTellingThemWeType else { return }
        isTellingThemWeType = false

        try? await room.typingNotice(isTyping: false)
    }

    /// How long a pause counts as having stopped. Long enough to think of the next word, short
    /// enough that a person who has walked away stops being described as writing.
    private static let typingLull = 4

    /// Loads older messages. Called when the user scrolls to the top.
    public func loadMore() async {
        // One failure is enough. `RoomView` asks for history on every change of scroll geometry —
        // deliberately, and the comment there explains why it is right to ask eagerly: `loadMore`
        // was supposed to be free to call. Offline it is the opposite of free. The page fails, the
        // reader is still near the top, the next frame asks again, and the room spends every frame
        // of every scroll going into Rust to be told once more that there is no network. That is the
        // stutter; the line at the top of the list blinking in and out of existence was the same
        // loop, seen.
        //
        // So a failed page stops the *automatic* asking. It does not stop the reader: pressing the
        // line at the top of the room calls `loadMoreHistory`, which clears this and tries again. Nor
        // does it outlive the network — `connectivityChanged(offline:)` clears it the moment sync
        // reports it is back, and the conversation goes on filling as though nothing had happened.
        guard !didFailToPaginate else { return }

        // The spinner belongs to the user's own scroll: it answers a request they made. A refill
        // is repair work nobody asked for, going on behind a conversation that is still on the
        // screen, and announcing it with a progress view above the first message would only be
        // the flicker coming back wearing something else.
        await page(showingSpinner: !isRefilling)
    }

    /// One page of history, and never two at once.
    ///
    /// The re-entrancy guard and the spinner used to be the *same* flag — `isPaginating = !isRefilling`
    /// — and one variable doing two jobs broke both of them:
    ///
    /// - During a refill the guard was never raised at all, so a user scrolling to the top while
    ///   the repair was running issued a **second concurrent** `paginateBackwards`. Both wrote
    ///   `canLoadMore`, and whichever answered last won — including flipping it back to `true`
    ///   after the real start of the room had been reached.
    /// - And in the other direction, a refill that arrived while a user page was in flight was
    ///   simply *turned away* — while `fillPages` counted the turn-away as an attempt. Twenty
    ///   attempts could burn through without fetching a single event, and the refill would then
    ///   publish the empty conversation it had failed to fetch. Reacting to a message during a
    ///   slow pagination emptied the room, which is precisely what `refill()` exists to prevent.
    ///
    /// So the guard is a task now, not a flag, and a caller who finds a page already in flight
    /// **waits for it** rather than being sent away empty-handed. The spinner is a separate
    /// thing that only the user's own scroll ever lights.
    ///
    /// Returns whether a page was actually fetched *by this call*. Waiting for somebody else's is
    /// not fetching one, and `fillPages` has to be able to tell the difference — see the two
    /// counters there.
    @discardableResult
    private func page(showingSpinner: Bool) async -> PageOutcome {
        // Somebody else's page is already on its way. Wait for it and let the caller re-examine
        // the world — `fillPages` will look again and take another turn if it still needs one.
        //
        // And then put the handle down if it is still the one we waited on. It is the *owner* of a
        // page that normally clears this, and there is one path where the owner cannot: a page that
        // comes back to find the generation has moved on returns without touching the field, because
        // by then it may belong to the room that replaced ours. If `stop()` has not run in between —
        // a resync, a failed opening that tore itself down and started again — nothing else clears
        // it either, and the handle is left pointing at a task that finished long ago.
        //
        // That is the shape of "sometimes a room opens with only the last message in it". Every
        // later call takes this branch, `await` on a finished task returns instantly, and `page`
        // answers `.waited` without ever going near the network. `fillPages` spends its whole wait
        // budget in a few microseconds, the opening ends having fetched nothing, and the room
        // settles on whatever the SDK's first reset happened to carry — the live tail, which is one
        // message. Scrolling could not mend it either: `loadMore` goes through here too.
        //
        // Clearing it makes the next turn of the loop fetch for real, which is the recovery the
        // symptom needs whatever left the handle stale. Guarded on identity so a wait that
        // overlapped a *live* page started by somebody else does not pull that one out from under
        // them.
        if let inFlight = pageInFlight {
            _ = await inFlight.value
            // `==`, because a `Task` is a struct — identity here is the handle's own equality,
            // which the standard library defines as pointing at the same task.
            if pageInFlight == inFlight { pageInFlight = nil }
            return .waited
        }

        // No timeline is not "no more history" — it is a room that is not open. Saying `waited`
        // here would have `fillPages` spin its whole budget against a room that cannot answer.
        guard let timeline else { return .failed }
        guard canLoadMore else { return .waited }

        if showingSpinner { isPaginating = true }

        // The room this page belongs to. `paginateBackwards` can take as long as the network does,
        // and the reader can leave and come back inside it — at which point `timeline` here is a
        // handle on a conversation nobody is looking at any more, and `canLoadMore` describes a
        // timeline that no longer exists. Writing it into the room that replaced it is how a room
        // that had been read to its beginning came back claiming there was more.
        let generation = self.generation

        let task = Task { @MainActor [weak self] () -> Bool in
            // `paginateBackwards` returns true once it has hit the start of the room.
            //
            // And it *throws* when the page could not be fetched at all — a server that is not
            // answering, a store that could not be read. That used to be swallowed by a `try?`
            // and reported to `fillPages` as a page like any other, which is the bug: four
            // failures in a row spent the whole opening budget without fetching a single event,
            // and the loop then walked away from a room it had put nothing in.
            // Bounded, and the timeout joins the throw above: a server that accepts the request and
            // then says nothing is exactly the "page that could not be fetched" this already knows
            // how to survive — `.failed` on the way out, and during an opening `open()` turns an
            // empty first page into the "try again" screen rather than a spinner without end.
            guard let reachedStart = try? await withTimeout(Self.sdkTimeout, operation: {
                try await timeline.paginateBackwards(numEvents: Self.pageSize)
            }) else {
                return false
            }

            guard let self, generation == self.generation else { return true }
            self.canLoadMore = !reachedStart
            return true
        }
        pageInFlight = task

        let didFetch = await task.value

        guard generation == self.generation else {
            // The reader left mid-page. Nothing below is ours to write — `canLoadMore`,
            // `isPaginating` and `didFailToPaginate` all describe the room that replaced ours — but
            // the handle is, if it is still ours. Leaving it set is what stranded the next opening;
            // see the wait at the top of this function.
            if pageInFlight == task { pageInFlight = nil }
            return .fetched
        }

        pageInFlight = nil
        isPaginating = false

        // Remembered rather than merely returned. `fillPages` acts on this and then forgets it, but
        // the *screen* has to go on knowing: it is the difference between offering a button that
        // fetches the rest of the conversation and explaining that the rest of it is on the other
        // side of a network that is not there. See `didFailToPaginate`.
        didFailToPaginate = !didFetch

        return didFetch ? .fetched : .failed
    }

    /// What one turn round `fillPages` actually achieved — and the reason it is three answers
    /// rather than a `Bool`. A page that was *not fetched* is either somebody else's page we
    /// waited on, which costs nothing and can be tried again in a moment, or a page that failed,
    /// which will go on failing and must not be paid for out of the same budget.
    private enum PageOutcome {
        case fetched
        case waited
        case failed
    }

    /// How many *events* a page of history is. Not messages: a page can come back as twenty-five
    /// joins and topic changes and put two bubbles on the screen, which is why `fillPages` asks
    /// again rather than trusting one page to fill anything.
    ///
    /// Named because it is already spoken of by name elsewhere — `RoomView` reasons out loud about
    /// "ten pages of twenty-five events" — and a number two files apart from the sentence that
    /// depends on it is a number that drifts.
    private static let pageSize: UInt16 = 25

    // MARK: - Diff handling

    private func apply(diffs: [TimelineDiff]) {
        let held = items.count

        // Did the SDK throw the timeline away in this batch? A `clear` or a `reset` is the only
        // way it says so, and it is the *reason* for a shrink rather than the shrink itself: a
        // message being deleted removes an item too, and that is not a conversation being lost.
        let wasThrownAway = diffs.contains { diff in
            switch diff {
            case .clear, .reset: true
            default: false
            }
        }

        // The dozen positional operations, and the three bounds checks that decide whether this
        // conversation is still the conversation the SDK is describing. They live in `ListDiff` —
        // out of reach of the SDK's types, and therefore, at last, under a test.
        switch items.apply(diffs.map(\.asListDiff)) {
        case let .desynced(what):
            return desynced(what)
        case .applied:
            break
        }

        // The conversation we had a moment ago is gone. Go and get it back — and say so *first*,
        // before the rows are rebuilt, because the rebuild is what would otherwise put the empty
        // room on the screen. `refill()` raises the flag that tells `rebuildRows()` to hold on to
        // the conversation the reader is looking at, and it measures how much of it to fetch back
        // from the rows that are still standing. One statement later, both would be gone.
        //
        // "Shrank", not "emptied", and that is a real difference rather than a defensive widening.
        // The condition used to be `items.isEmpty`, which only catches the SDK clearing the
        // timeline and repopulating it in *two* batches. It is equally entitled to do it in one —
        // `[.clear, .append(liveTail)]`, or a `.reset` carrying the live tail — and then `items`
        // is not empty at this point, no refill runs, and the reader who had paginated back
        // through a week of conversation is quietly dropped at the live end of it. Same bug,
        // wearing the batched form of the same SDK behaviour.
        if held > 0, items.count < held, wasThrownAway { refill() }

        // Deliberately does *not* set `hasLoaded`. The first diff to arrive is the SDK's
        // empty reset, which is proof of nothing except that the room is listening — and
        // treating it as proof of loading is what would flash "no messages yet" across a
        // conversation whose first page is still in flight. `open()` decides when the room
        // has loaded, because only it knows the page has landed.
        rebuildRows()
    }

    /// The timeline is no longer the timeline the SDK is talking about, so it is read again.
    ///
    /// Not `refill()`, and the difference matters. A refill answers the SDK *throwing the
    /// conversation away* — the items we hold are right, there are simply none of them, and more
    /// are fetched. This answers the items we hold being **wrong**, and no amount of fetching
    /// fixes a list that is out of step: what fixes it is being told the list again. Stopping and
    /// starting does exactly that, because a fresh listener opens with a `reset` — the SDK's own
    /// account of what it is holding, which is the thing we have lost.
    ///
    /// The reader keeps their conversation throughout. `stop()` leaves `rows` alone and `open()`
    /// holds them on screen while it fetches back to the depth they had — the reopening path,
    /// already there for pushing a screen over a room and coming back to it.
    ///
    /// It is an `assertionFailure` in debug because it is a bug every time. Nothing in the
    /// protocol makes an impossible index legitimate: if we are seeing one, either we applied
    /// something out of order or we misunderstood a diff, and both are ours to fix. In release it
    /// recovers rather than dies — a wrong sentence on the screen is worse than a slow one, but
    /// a crash is worse than both.
    private func desynced(_ what: String) {
        guard !isResyncing else { return }
        isResyncing = true

        Log.rooms.error("Timeline out of step with the SDK: \(what, privacy: .public). Reading the room again.")
        assertionFailure("Timeline desynchronised: \(what)")

        Task { @MainActor [weak self] in
            guard let self else { return }
            stop()
            try? await start()
            isResyncing = false
        }
    }

    /// The single place the SDK's items become rows, so that a reaction we know never sent is
    /// subtracted from *every* rebuild — including the ones the SDK triggers on its own, which
    /// would otherwise put the pill straight back.
    ///
    /// It is also where the screen is protected from the SDK emptying the room under it.
    ///
    /// Deleting a message or reacting to one makes the event cache throw the timeline away and
    /// rebuild it (see `refill()`), and it used to do that *on screen*: the rows went to zero,
    /// the conversation blanked, the placeholder and the spinner had time to appear, and the
    /// re-fetched messages then dropped back in — which scrolled the view to the bottom, because
    /// the last row had "changed". A whole chat reloading because one reaction was pressed.
    ///
    /// Nothing was wrong with the data; it was only ever the *empty moment in the middle* that
    /// the user saw. So it is not shown. While a refill is running the last good conversation
    /// stays on the screen, and the rebuilt one is published when it is at least as complete as
    /// what it replaces — same rows, same identities, same scroll position, and the deleted
    /// message quietly becomes "message deleted" in place.
    /// Settings → Chats changed which grey lines are shown; the conversation on screen follows at
    /// once rather than on its next diff.
    public func serviceEventSettingsChanged() {
        rebuildRows()
    }

    private func rebuildRows() {
        var built = TimelineMapper.rows(from: items, ownUserID: ownUserID, unsent: unsentReactions,
                                        hiding: ServiceEventSettings.current())

        // The messages we have sent and not yet been shown, added to the end of the conversation —
        // and dropped again the moment the SDK's own echo of one turns up among the rows above.
        // Pruned before they are appended, because the echo lands as an ordinary diff and this is
        // the rebuild that carries it: appending first would put the same sentence in the
        // conversation twice for one frame. See `PendingSends`.
        if !pending.isEmpty {
            // Which echo took over from which of our bubbles, remembered so the screen can keep
            // the row rather than replace it. See `viewIdentity(of:)`.
            adopted.merge(pending.pruneEchoed(in: built)) { _, new in new }
            built.append(contentsOf: pendingRows(after: built))
        }

        // Only for as long as the message it belongs to is on the screen. A conversation
        // scrolled far enough back drops its oldest rows, and a mapping nothing refers to any
        // more is a mapping nobody will ever look up.
        if !adopted.isEmpty {
            let present = Set(built.map(\.id))
            adopted = adopted.filter { present.contains($0.key) }
        }

        latestRows = built

        // A reply whose original the SDK is holding nothing for is not a lost message — it is a
        // message nobody has asked for. Ask.
        fetchReplyDetails()

        // Half a conversation is not an improvement on the whole one the reader is looking at.
        if isRefilling, latestRows.count < rows.count { return }

        rows = latestRows
    }

    /// The ID a row should be drawn under, which is not always the ID it *is*.
    ///
    /// They differ for exactly one thing, and briefly: a message of ours between being sent and
    /// being echoed. Our own bubble goes up the instant send is pressed — that is what
    /// `PendingSends` is for — and the server's echo of it arrives a fraction of a second later
    /// with a real event ID. To everything below the screen those are two different rows, and
    /// SwiftUI dutifully destroyed one view and built another: which is why a message you sent
    /// never got the arrival it was given, while a message somebody sent *you* rose into place
    /// as intended. The echo was replacing the bubble mid-animation, and whichever of the two
    /// came second was drawn standing still.
    ///
    /// So the echo inherits the bubble's identity for as long as it is on the screen, and the
    /// conversation keeps one row throughout. Only the *drawing* uses this. Everything that acts
    /// on a message — replying, reacting, pinning, jumping to it — keeps using its real ID,
    /// because that is the ID the server knows and the only one an action can be sent with.
    public func viewIdentity(of row: TimelineRow) -> String {
        adopted[row.id] ?? row.id
    }

    /// Echoes that have taken over from a bubble of ours: the real message's ID against the ID
    /// the row already had on screen. See `viewIdentity(of:)`.
    private var adopted: [String: String] = [:]

    /// Turns the messages still on their way out into rows at the end of the conversation.
    ///
    /// A stand-in is a real `Message` with a real `.sending` delivery, so everything the screen
    /// already knows applies to it unchanged: it is drawn as a bubble on our side with a clock
    /// beside it, it cannot be reacted to or edited or deleted — `canReact` and its neighbours
    /// all turn on that same `.sending` — and nothing goes looking for a send handle it does not
    /// have, because its ID belongs to no event.
    ///
    /// No day divider is invented above it. A divider is the mapper's to place and it places one
    /// from the SDK's own virtual item; guessing at it here would put a second, differently
    /// identified line on the screen a moment before the real one arrived. The only message this
    /// costs is the first of a new day, which gains its divider when the echo lands.
    private func pendingRows(after rows: [TimelineRow]) -> [TimelineRow] {
        // Ourselves, as this room already draws us. There is no cheaper way to ask: the display
        // name and the picture live on the room member, fetching one is a call and an await, and
        // an await is the single thing a message that must appear *now* cannot afford. The
        // conversation is holding the answer already — it is above every message we have sent in
        // it — and in a room where we have said nothing yet the ID is what the SDK would fall
        // back to anyway.
        let me = rows.reversed().lazy.compactMap(\.message).first { $0.isOwn }

        var previous = rows.last?.message
        var built: [TimelineRow] = []

        for item in pending.all {
            // Grouped under the message above it by the same rule the mapper uses, so that
            // sending three lines in a row does not put our name and face above each of them —
            // and so that nothing jumps when the echo replaces the stand-in with a row the
            // mapper has grouped for itself.
            let isContinuation = previous.map { above in
                above.senderID == ownUserID
                    && item.sentAt.timeIntervalSince(above.timestamp) < TimelineMapper.runWindow
            } ?? false

            let message = Message(id: item.id,
                                  kind: .text(item.text),
                                  senderID: ownUserID,
                                  senderName: me?.senderName ?? ownUserID,
                                  senderAvatarURL: me?.senderAvatarURL,
                                  isOwn: true,
                                  timestamp: item.sentAt,
                                  delivery: .sending,
                                  isEdited: false,
                                  replyTo: item.replyingTo.flatMap { quote(of: $0, in: rows) },
                                  reactions: [],
                                  isContinuation: isContinuation)

            built.append(.message(message))
            previous = message
        }

        return built
    }

    /// The strip above a reply that has not been sent yet, built from the message being answered
    /// as it stands on the screen.
    ///
    /// Nil where the original is no longer in the conversation — paginated away, or deleted
    /// between the quote being picked and send being pressed. A reply with no strip is a great
    /// deal better than a strip that says "Message unavailable" about a message that is plainly
    /// there: the echo arrives with the SDK's own resolved quote a moment later either way.
    private func quote(of messageID: String, in rows: [TimelineRow]) -> ReplyPreview? {
        guard let original = rows.lazy.compactMap(\.message).first(where: { $0.id == messageID }),
              let eventID = eventID(for: messageID) else { return nil }

        return ReplyPreview(eventID: eventID,
                            senderName: original.senderName,
                            text: MessagePreview.text(for: original.kind))
    }

    /// The replies we have already asked the SDK to finish, so that a rebuild does not ask again.
    ///
    /// Every rebuild would otherwise re-issue the same request: `rebuildRows()` runs on every diff,
    /// the details take a network round trip to arrive, and in between them the reply still reads
    /// as unresolved. A busy room would ask for the same original a dozen times.
    ///
    /// Emptied by `stop()`, with `items`. The next opening is a fresh timeline and its items are
    /// fresh SDK objects; what we asked the last one for tells us nothing about them.
    private var askedForReplyDetails: Set<String> = []

    /// Goes and gets the messages the replies on screen are answering.
    ///
    /// This is the whole of why a reply to anything older than the current screenful read
    /// "Message unavailable" — including, maddeningly, after the original had been paginated back
    /// in and was sitting in plain view a few rows up. The SDK resolves an `inReplyTo` only when
    /// asked to (`fetchDetailsForEvent`), it says so by answering `.unavailable` rather than by
    /// failing, and this app had simply never asked. Nothing was broken; nobody was fetching.
    ///
    /// The answer arrives as an ordinary diff — the SDK updates the item in place and the timeline
    /// listener brings it back through `apply` — so there is nothing to write here and nothing to
    /// wait for. Which is also why the quote fixes itself on screen rather than only on reopening.
    private func fetchReplyDetails() {
        guard let timeline else { return }

        let missing = TimelineMapper.repliesMissingTheirOriginal(in: items)
            .filter { !askedForReplyDetails.contains($0) }

        guard !missing.isEmpty else { return }
        askedForReplyDetails.formUnion(missing)

        Task {
            for eventID in missing {
                // A reply nobody can resolve — the original was redacted, or is on a server that
                // will not hand it over — is not an error worth reporting. The quote already says
                // what it can, and it is the true thing to say.
                try? await timeline.fetchDetailsForEvent(eventId: eventID)
            }
        }
    }

    /// Fetches the conversation again after the SDK has thrown it away.
    ///
    /// It does throw it away, and it is entitled to: the event cache clears a timeline and
    /// rebuilds it whenever it decides what it holds can no longer be trusted to be
    /// continuous — after a redaction, after a gappy sync, after a reaction has been echoed
    /// back by the server. The SDK says so in the only way it can, a `clear` or an empty
    /// `reset`, and then it repopulates the *live* end of the timeline and stops.
    ///
    /// It stops because history is fetched here, not streamed — the same fact that makes a
    /// freshly opened room start out empty (see `open()`). Nothing was asking for it again,
    /// so a chat that had been read to the end simply emptied and stayed empty: the user had
    /// paginated to the start of the room, `canLoadMore` was false, and an empty screen
    /// cannot be scrolled to ask for more. Reacting to a message, or deleting one, threw away
    /// the conversation it belonged to.
    ///
    /// `canLoadMore` goes back to true because it is a statement about the timeline we hold,
    /// and we no longer hold it: whatever we had paginated back to went with the rest.
    /// It is fetched back to the depth the reader had already pulled in, not to one screenful.
    /// Somebody who has scrolled up through a week of conversation and then deletes a message
    /// should not be dropped at the live end of a room they had left twenty minutes ago — and
    /// `rows` is exactly the measure of how much of it they were holding.
    private func refill() {
        guard refillTask == nil else { return }

        canLoadMore = true
        isRefilling = true
        let depth = rows.count

        // The room being repaired. A refill outlives `stop()` — it is a long chain of paginations
        // and nothing in it was ever cancellable — and it used to wake up inside the *next*
        // `open()` and publish `latestRows`, which at that moment is the new listener's empty
        // reset. Delete a message, leave the room, come back: the conversation blinked empty, and
        // the guard in `rebuildRows()` that exists to stop precisely that had just been switched
        // off by the same zombie.
        let generation = self.generation

        refillTask = Task { [weak self] in
            await self?.fillPages(untilAtLeast: depth, maximumPages: Self.maximumRefillPages)

            guard let self, generation == self.generation else { return }

            // Whatever came back is now the conversation, even if it is shorter than what was on
            // the screen — a room really can have less in it than it did a moment ago, and going
            // on showing the old rows at that point would be the app refusing to believe it.
            isRefilling = false
            refillTask = nil
            rows = latestRows
        }
    }
}

/// The room telling us it has changed — a new name, a new picture, somebody pinning a message.
///
/// `RoomInfo` is `Sendable`, so it crosses from the Rust callback thread on its own; unlike the
/// timeline's diffs, it needs no `UnsafeTransfer` to carry it.

private final class RoomQueueListener: SendQueueListener {
    private let onUpdate: @Sendable (RoomSendQueueUpdate) -> Void

    init(onUpdate: @escaping @Sendable (RoomSendQueueUpdate) -> Void) {
        self.onUpdate = onUpdate
    }

    func onUpdate(update: RoomSendQueueUpdate) {
        onUpdate(update)
    }
}

/// The room telling us who is writing. `[String]` is `Sendable`, so it needs no `UnsafeTransfer`.
final class TypingListener: TypingNotificationsListener {
    private let onUpdate: @Sendable ([String]) -> Void

    init(onUpdate: @escaping @Sendable ([String]) -> Void) {
        self.onUpdate = onUpdate
    }

    func call(typingUserIds: [String]) {
        onUpdate(typingUserIds)
    }
}

private final class ItemsListener: TimelineListener {
    private let onDiff: @Sendable ([TimelineDiff]) -> Void

    init(onDiff: @escaping @Sendable ([TimelineDiff]) -> Void) {
        self.onDiff = onDiff
    }

    func onUpdate(diff: [TimelineDiff]) {
        onDiff(diff)
    }
}
