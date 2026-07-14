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
    public private(set) var privacy: PrivacyStatus = .unknown
    public private(set) var roomName: String = ""

    /// True when there is exactly one other person here. A conversation with one other
    /// person does not need their name and face repeated above every message they send —
    /// you know who they are, and the messages are on their side of the screen.
    public private(set) var isDirectChat = false

    /// What the header above the conversation needs, and nothing more. The room *info*
    /// screen asks for the rest — members, topic, notifications — through
    /// `UserSession.details(forRoomID:)`, because that is a screenful of requests and this
    /// is a title bar.
    public private(set) var roomAvatarURL: String?
    public private(set) var memberCount = 0

    /// The other person's Matrix ID, in a chat that has exactly one other person.
    ///
    /// This is what the header shows under their name. It is deliberately *not* a "last
    /// seen" time: the Rust SDK exposes no presence at all over FFI, and a timestamp
    /// invented from their last message would say "online 5 minutes ago" about someone
    /// who has been reading over your shoulder in silence all day. The Matrix ID is the
    /// thing people actually ask each other for.
    public private(set) var directCounterpartID: String?

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

        if let info = try? await room.roomInfo() {
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

        let timeline = try await room.timeline()

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

        diffTask = Task { @MainActor [weak self] in
            for await batch in diffs {
                self?.apply(diffs: batch.value)
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

        // Only now. Between the empty reset and the first page there is a moment where the
        // room is genuinely empty and genuinely not loaded, and saying "no messages yet"
        // into that gap would be wrong about a conversation that is one await away.
        hasLoaded = true
    }

    /// Everything the header and the pinned strip read, taken from the room as it now is.
    private func adopt(_ info: RoomInfo) {
        privacy = PrivacyStatus(info.encryptionState)
        roomName = info.displayName ?? info.heroes.first?.displayName ?? String(core: CoreStrings.Room.untitled)
        isDirectChat = info.isDm
        roomAvatarURL = info.avatarUrl
        memberCount = Int(info.joinedMembersCount)
        pinnedEventIDs = info.pinnedEventIds
        // The heroes are the people the server names to describe a room that has no
        // name of its own — in a DM, that is the person you are talking to. Falling
        // back to nothing (rather than to our own ID) is right: a note-to-self room
        // has no counterpart, and claiming one would put your own address in the
        // header of your own chat.
        directCounterpartID = info.isDm ? info.heroes.first(where: { $0.userId != ownUserID })?.userId : nil
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

        // Sending is the end of writing. Waiting for the four-second lull to notice would leave
        // the other person watching "typing…" for four seconds *after* the message had landed in
        // front of them, which is the one moment it is obviously untrue.
        await stoppedTyping()

        // Not logged, not stored anywhere but the SDK's encrypted send queue.
        let content = messageEventContentFromMarkdown(md: trimmed)

        do {
            if let replyID, let eventID = eventID(for: replyID) {
                try await timeline.sendReply(msg: content, eventId: eventID)
            } else {
                _ = try await timeline.send(msg: content)
            }
        } catch {
            failure = .send
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
    private func handle(sendQueueUpdate update: RoomSendQueueUpdate) {
        guard case .sendError = update else { return }
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
    public func markAsRead() async {
        try? await room.markAsRead(receiptType: .read)
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
        guard let draft = (try? await room.loadComposerDraft(threadRoot: nil)) ?? nil else {
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
            let name = (try? await room.memberDisplayName(userId: userID)) ?? nil
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
        if let inFlight = pageInFlight {
            await inFlight.value
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
            guard let reachedStart = try? await timeline.paginateBackwards(numEvents: Self.pageSize) else {
                return false
            }

            guard let self, generation == self.generation else { return true }
            self.canLoadMore = !reachedStart
            return true
        }
        pageInFlight = task

        let didFetch = await task.value

        guard generation == self.generation else { return .fetched }

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
    private func rebuildRows() {
        latestRows = TimelineMapper.rows(from: items, ownUserID: ownUserID, unsent: unsentReactions)

        // A reply whose original the SDK is holding nothing for is not a lost message — it is a
        // message nobody has asked for. Ask.
        fetchReplyDetails()

        // Half a conversation is not an improvement on the whole one the reader is looking at.
        if isRefilling, latestRows.count < rows.count { return }

        rows = latestRows
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
private final class TypingListener: TypingNotificationsListener {
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
