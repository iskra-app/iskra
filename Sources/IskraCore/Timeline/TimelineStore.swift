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

    /// Set when sending fails in a way the user should know about.
    public var sendFailure: LocalizedStringResource?

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

    private let room: Room
    private let ownUserID: String
    private var timeline: Timeline?

    /// The SDK timeline, for the media-sending extension in `TimelineStore+Media`.
    /// Nil until `start()` has run.
    var liveTimeline: Timeline? { timeline }
    private var listenerHandle: TaskHandle?
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
    private var pageInFlight: Task<Void, Never>?

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

    public func start() async throws {
        guard timeline == nil else { return }

        didFailToLoad = false

        do {
            try await open()
        } catch {
            // Recorded as well as thrown. The screen needs to be able to say "this chat
            // didn't open" and offer to try again — `try?` at the call site would swallow
            // the failure and leave it showing an empty room instead, which is a lie about
            // a conversation that may be full of messages.
            didFailToLoad = true

            // And whatever `open()` raised on its way in comes back down. A reopen that threw
            // half way would otherwise leave `isRefilling` up for good, and `rebuildRows` would
            // go on refusing to publish anything shorter than the rows already there — a room
            // frozen at the moment it failed, which is the bug this whole pass is about.
            isRefilling = false
            timeline = nil

            throw error
        }
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

        if let info = try? await room.roomInfo() {
            adopt(info)
        }

        // And then keep it up to date. A room is renamed, somebody pins a message, a person
        // joins — all of that arrives here, and none of it used to: the header and the pinned
        // strip were a snapshot taken when the room was opened and never looked at again.
        roomInfoHandle = room.subscribeToRoomInfoUpdates(listener: RoomInfoUpdates { [weak self] info in
            Task { @MainActor [weak self] in
                self?.adopt(info)
            }
        })

        let timeline = try await room.timeline()
        self.timeline = timeline

        let listener = ItemsListener { [weak self] diffs in
            let transfer = UnsafeTransfer(value: diffs)
            Task { @MainActor [weak self] in
                self?.apply(diffs: transfer.value)
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
        var attempts = 0
        while latestRows.count < minimumRows, canLoadMore, attempts < maximumPages {
            await loadMore()
            attempts += 1
        }
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
        refillTask?.cancel()
        refillTask = nil
        listenerHandle?.cancel()
        listenerHandle = nil
        sendQueueHandle?.cancel()
        sendQueueHandle = nil
        roomInfoHandle?.cancel()
        roomInfoHandle = nil

        timeline = nil
        // The SDK's items belong to the timeline that has just gone. A fresh listener opens with
        // an empty reset and repopulates from scratch, and leaving the old ones here would have
        // the next `apply` computing diffs against a timeline that no longer exists.
        items = []

        isPaginating = false
        isRefilling = false
        pageInFlight = nil
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
        guard !trimmed.isEmpty, let timeline else { return }

        // Not logged, not stored anywhere but the SDK's encrypted send queue.
        let content = messageEventContentFromMarkdown(md: trimmed)

        do {
            if let replyID, let eventID = eventID(for: replyID) {
                try await timeline.sendReply(msg: content, eventId: eventID)
            } else {
                _ = try await timeline.send(msg: content)
            }
        } catch {
            sendFailure = CoreStrings.Timeline.sendFailed
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
            sendFailure = CoreStrings.Timeline.editFailed
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
            sendFailure = CoreStrings.Timeline.reactionFailed
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
        sendFailure = CoreStrings.Timeline.reactionFailed
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
            sendFailure = CoreStrings.Timeline.deleteFailed
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
            sendFailure = CoreStrings.Timeline.pinFailed
        }
    }

    public func unpin(messageID: String) async {
        guard let timeline, let eventID = eventID(for: messageID) else { return }

        do {
            _ = try await timeline.unpinEvent(eventId: eventID)
        } catch {
            sendFailure = CoreStrings.Timeline.pinFailed
        }
    }

    /// Everything the room has pinned, as its own conversation — for the "Pinned" screen, and
    /// for the strip above the room that shows the latest of them.
    ///
    /// A second timeline over the same room, which the SDK supports directly: a
    /// `TimelineFocus.pinnedEvents` timeline holds exactly the pinned events and follows them
    /// as they change. It is built on demand, because most rooms have nothing pinned and an
    /// unopened one costs nothing.
    public func pinned() -> PinnedStore {
        PinnedStore(room: room, ownUserID: ownUserID)
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
    private func message(_ id: String) -> Message? {
        for row in rows {
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

    /// Loads older messages. Called when the user scrolls to the top.
    public func loadMore() async {
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
    private func page(showingSpinner: Bool) async {
        // Somebody else's page is already on its way. Wait for it and let the caller re-examine
        // the world — `fillPages` will look again and take another turn if it still needs one.
        if let inFlight = pageInFlight {
            await inFlight.value
            return
        }

        guard let timeline, canLoadMore else { return }

        if showingSpinner { isPaginating = true }

        let task = Task { @MainActor [weak self] in
            // `paginateBackwards` returns true once it has hit the start of the room.
            if let reachedStart = try? await timeline.paginateBackwards(numEvents: 25) {
                self?.canLoadMore = !reachedStart
            }
        }
        pageInFlight = task

        await task.value

        pageInFlight = nil
        isPaginating = false
    }

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

        for diff in diffs {
            switch diff {
            case let .append(values):
                items.append(contentsOf: values)
            case .clear:
                items.removeAll()
            case let .pushFront(value):
                items.insert(value, at: 0)
            case let .pushBack(value):
                items.append(value)
            case .popFront:
                if !items.isEmpty { items.removeFirst() }
            case .popBack:
                if !items.isEmpty { items.removeLast() }
            case let .insert(index, value):
                items.insert(value, at: min(Int(index), items.count))
            case let .set(index, value):
                let i = Int(index)
                if items.indices.contains(i) { items[i] = value }
            case let .remove(index):
                let i = Int(index)
                if items.indices.contains(i) { items.remove(at: i) }
            case let .truncate(length):
                let n = Int(length)
                if n < items.count { items.removeSubrange(n...) }
            case let .reset(values):
                items = values
            }
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

        // Half a conversation is not an improvement on the whole one the reader is looking at.
        if isRefilling, latestRows.count < rows.count { return }

        rows = latestRows
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

        refillTask = Task { [weak self] in
            await self?.fillPages(untilAtLeast: depth, maximumPages: Self.maximumRefillPages)

            guard let self else { return }
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
private final class RoomInfoUpdates: RoomInfoListener {
    private let onUpdate: @Sendable (RoomInfo) -> Void

    init(onUpdate: @escaping @Sendable (RoomInfo) -> Void) {
        self.onUpdate = onUpdate
    }

    func call(roomInfo: RoomInfo) {
        onUpdate(roomInfo)
    }
}

private final class RoomQueueListener: SendQueueListener {
    private let onUpdate: @Sendable (RoomSendQueueUpdate) -> Void

    init(onUpdate: @escaping @Sendable (RoomSendQueueUpdate) -> Void) {
        self.onUpdate = onUpdate
    }

    func onUpdate(update: RoomSendQueueUpdate) {
        onUpdate(update)
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
