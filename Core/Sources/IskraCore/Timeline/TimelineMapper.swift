import Foundation
import MatrixRustSDK

/// Turns the SDK's timeline items into the value types the UI renders.
///
/// This is the only place that knows about `MsgLikeKind`, `EventSendState` and the
/// rest of the SDK's vocabulary. Everything above it deals in `Message`s.
enum TimelineMapper {
    /// How close together two messages from the same person have to be to read as one remark
    /// continued rather than two remarks.
    ///
    /// Five minutes. A product decision and not a protocol one, which is exactly why it is named:
    /// as a bare `300` in the middle of a condition it read as a number somebody had to look up,
    /// and the one thing it is not is a number anybody can look up. Only the first message in a run
    /// carries a name and a face; this is where a run ends.
    static let runWindow: TimeInterval = 5 * 60

    /// What a waveform sample means on the wire.
    ///
    /// The Matrix voice-message extension carries `0...1024` per sample and the interface wants
    /// `0...1`, so every sample is divided by this on the way in and multiplied by it on the way
    /// out (`TimelineStore+Media`). It was written out as a bare `1024` in both, which is the
    /// classic shape of a bug that only appears if somebody changes one of them: the waveforms
    /// would all be a thousand times too tall, and only on messages this app had sent.
    static let waveformScale = 1024

    /// What one SDK item comes to, before it meets its neighbours.
    ///
    /// Everything here is a function of the item alone (and of who we are, which does not change
    /// for the life of a timeline) — which is what lets `Memo` keep it. The passes that need the
    /// neighbours — runs, merged grey lines, the read watermark, the unread bar — are cheap Swift
    /// over these and run every time.
    struct Mapped {
        enum Body {
            case dayDivider(DayDivider)
            case readMarker
            case event(RoomEvent)
            /// With the reactions as the SDK reported them; `UnsentReactions` is applied later,
            /// because it changes without the item changing.
            case message(Message)
            case nothing
        }

        let body: Body
        /// Somebody other than us has a read receipt on this item — see `rows(from:)`.
        let hasForeignReceipt: Bool
        /// When they did, for an item that has one. See `readAt(of:ownUserID:)`.
        let receiptReadAt: Date?
        /// The reply's own event ID, for a reply whose original the SDK holds nothing for — see
        /// `repliesMissingTheirOriginal`.
        let unresolvedReply: String?
    }

    /// The items already mapped, held by the very object the SDK handed over.
    ///
    /// Without it every diff — a receipt, a reaction, one new message — mapped the *whole*
    /// timeline again, and mapping is not Swift work: `asEvent()` lifts the entire record across
    /// the FFI (content, receipts, reactions, profile), and it was being called three times per
    /// item per diff — twice in `rows` and once more for the replies. A room paginated back a few
    /// hundred messages paid a few hundred record lifts, on the main thread, for one tick.
    ///
    /// Keyed by identity, and that is sound rather than clever: an SDK item is an immutable
    /// snapshot, a change to a message arrives as a `set` carrying a *new* object, and an object
    /// still in `items` is the same object it was. The entry holds the item strongly, so its
    /// address cannot be reused by another while the entry exists; `===` is checked anyway.
    /// Pruned to the items passed on every call, so it never holds more than the timeline does.
    final class Memo {
        private var entries: [ObjectIdentifier: (item: TimelineItem, mapped: Mapped)] = [:]

        /// The replies in the last mapping whose originals are missing, in timeline order.
        private(set) var unresolvedReplies: [String] = []

        init() {}

        func mapped(_ items: [TimelineItem], ownUserID: String) -> [Mapped] {
            var next: [ObjectIdentifier: (item: TimelineItem, mapped: Mapped)] = [:]
            next.reserveCapacity(items.count)
            var replies: [String] = []

            let result = items.map { item -> Mapped in
                let key = ObjectIdentifier(item)
                let mapped: Mapped
                if let entry = entries[key], entry.item === item {
                    mapped = entry.mapped
                } else {
                    mapped = TimelineMapper.map(item, ownUserID: ownUserID)
                }
                next[key] = (item, mapped)
                if let reply = mapped.unresolvedReply { replies.append(reply) }
                return mapped
            }

            entries = next
            unresolvedReplies = replies
            return result
        }

        /// Lets go of every SDK item — for a store putting its timeline down.
        func removeAll() {
            entries.removeAll()
            unresolvedReplies.removeAll()
        }
    }

    static func map(_ item: TimelineItem, ownUserID: String) -> Mapped {
        if let virtual = item.asVirtual() {
            let body: Mapped.Body = switch virtual {
            case let .dateDivider(timestamp):
                .dayDivider(DayDivider(id: "divider-\(timestamp)", date: MessagePreview.date(from: timestamp)))
            case .readMarker:
                .readMarker
            default:
                .nothing
            }
            return Mapped(body: body, hasForeignReceipt: false, receiptReadAt: nil, unresolvedReply: nil)
        }

        // Once. It is the expensive call — the whole record, lifted out of Rust.
        guard let event = item.asEvent() else {
            return Mapped(body: .nothing, hasForeignReceipt: false, receiptReadAt: nil, unresolvedReply: nil)
        }

        let foreign = hasForeignReceipt(event, ownUserID: ownUserID)
        let body: Mapped.Body
        if let roomEvent = roomEvent(from: event) {
            body = .event(roomEvent)
        } else if let message = message(from: event, ownUserID: ownUserID) {
            body = .message(message)
        } else {
            body = .nothing
        }

        return Mapped(body: body,
                      hasForeignReceipt: foreign,
                      receiptReadAt: foreign ? readAt(of: event, ownUserID: ownUserID) : nil,
                      unresolvedReply: unresolvedReply(of: event))
    }

    /// `ownUserID` is here for one reason: a reaction pill has to know whether *you* are
    /// among the people who left it, because pressing it again takes it back. The SDK
    /// tells us who reacted, not whether one of them is us.
    ///
    /// `unsent` is the reactions of ours that never left the send queue. The SDK goes on
    /// reporting them as though they had, so they are subtracted here — see `UnsentReactions`.
    ///
    /// `memo`, where the caller keeps one, is what spares the items that have not changed from
    /// being mapped again — see `Memo`.
    static func rows(from items: [TimelineItem],
                     ownUserID: String,
                     unsent: UnsentReactions = UnsentReactions(),
                     hiding hidden: ServiceEventSettings = ServiceEventSettings(),
                     memo: Memo? = nil) -> [TimelineRow] {
        let mapped = memo?.mapped(items, ownUserID: ownUserID)
            ?? items.map { map($0, ownUserID: ownUserID) }
        return rows(from: mapped, ownUserID: ownUserID, unsent: unsent, hiding: hidden)
    }

    static func rows(from mapped: [Mapped],
                     ownUserID: String,
                     unsent: UnsentReactions,
                     hiding hidden: ServiceEventSettings) -> [TimelineRow] {
        var rows: [TimelineRow] = []
        rows.reserveCapacity(mapped.count)

        var previous: Message?

        // How many rows are covered by somebody else's read receipt — see `withReadPropagated`.
        // Counted here, over the SDK's items, because a receipt names one event and that event is
        // very often not one of ours and sometimes not a row at all.
        var readPrefix = 0

        // And when they caught up. Lives on the same event as the watermark, which is why it is
        // picked up here with it: by the time the rows exist, the event that carried the moment
        // may well have been dropped, and the menu had nothing to show for a message everybody
        // could see was read.
        var readPrefixAt: Date?

        for item in mapped {
            // Whatever this item turns into — a row, a merged grey line, or nothing — everything
            // above it has been read the moment it carries a receipt. Recorded after the item is
            // handled, hence the `defer`, and counted in rows rather than in items so the number
            // still means something after the events this app never shows are dropped.
            defer {
                if item.hasForeignReceipt {
                    readPrefix = rows.count
                    readPrefixAt = item.receiptReadAt
                }
            }

            switch item.body {
            case let .dayDivider(divider):
                rows.append(.dayDivider(divider))
                // A date divider breaks the visual grouping.
                previous = nil

            case .readMarker:
                // Where the reader left off. A bar across the conversation, so it breaks a run
                // the same way a date does. See `TimelineRow.unreadDivider`.
                rows.append(.unreadDivider)
                previous = nil

            case let .event(roomEvent):
                // Something that happened rather than something somebody said. It goes in as a
                // grey line — and it may not go in at all, because two people joining one after
                // the other is one line and not two. See `append`.
                //
                // Switched off in Settings → Chats: dropped like any event this app never shows, so
                // it neither breaks a run of messages nor keeps an empty day's header alive.
                if hidden.hides(roomEvent.kind) { continue }
                append(roomEvent, to: &rows)
                // A note across the conversation breaks a run of messages: the one below it
                // is no longer "the same person still talking".
                previous = nil

            case var .message(message):
                if !unsent.isEmpty {
                    message.reactions = unsent.applied(to: message.reactions, messageID: message.id,
                                                       ownUserID: ownUserID)
                }

                // Group consecutive messages from the same person, iMessage-style: only
                // the first one in a run carries a name and an avatar.
                if let previous,
                   previous.senderID == message.senderID,
                   message.timestamp.timeIntervalSince(previous.timestamp) < runWindow {
                    message.isContinuation = true
                }

                rows.append(.message(message))
                previous = message

            case .nothing:
                continue
            }
        }

        // The bar first, then the empty days: a date whose only row was an unearned bar is a date
        // over nothing, and the second pass is the one that knows what to do about that.
        var finished = withoutEmptyDays(withUnreadDividerIfEarned(
            withReadPropagated(rows, readUpTo: readPrefix, at: readPrefixAt)))
        markRunEnds(&finished)
        return finished
    }

    /// Marks every message that has a continuation directly under it — see `Message.isContinued`.
    ///
    /// Done over the *finished* rows, after the passes that drop an unearned bar or an empty day,
    /// because what decides it is the row that really ends up below. And done again by whoever
    /// appends more rows — `TimelineStore`, with the messages still on their way — since a line
    /// sent under our own last message moves our face down onto it.
    static func markRunEnds(_ rows: inout [TimelineRow]) {
        for index in rows.indices {
            guard case var .message(message) = rows[index] else { continue }
            let next = rows.index(after: index)
            let continued = next < rows.endIndex && rows[next].message?.isContinuation == true
            guard message.isContinued != continued else { continue }
            message.isContinued = continued
            rows[index] = .message(message)
        }
    }

    /// Keeps the "Unread messages" bar only where there is something unread under it.
    ///
    /// The SDK places its read marker after the last event the account has read, and this app drops
    /// most of what the SDK holds — so the bar can end up over nothing but a member joining, or over
    /// nothing at all. And it can sit over messages that are only *ours*: the marker is the account's
    /// `m.fully_read`, which moves when a room is left (`TimelineStore.stop`), so a reply written on
    /// another device lands below it. "Unread" over your own words is the app not knowing who you
    /// are. Telegram shows the bar only above something somebody else said, and so does this.
    ///
    /// Not private: tested directly, for the same reason `withoutEmptyDays` is.
    static func withUnreadDividerIfEarned(_ rows: [TimelineRow]) -> [TimelineRow] {
        guard let index = rows.firstIndex(of: .unreadDivider) else { return rows }

        let earned = rows[(index + 1)...].contains { row in
            guard case let .message(message) = row else { return false }
            return !message.isOwn
        }

        var rows = rows
        rows.remove(at: index)
        // Only the first: there is one read marker in a timeline, and a second bar would be the
        // same fact said twice.
        rows.removeAll { $0 == .unreadDivider }
        if earned { rows.insert(.unreadDivider, at: index) }
        return rows
    }

    /// Marks your earlier messages read once a later one has been.
    ///
    /// A Matrix read receipt names a single event: the last one the reader got to. The SDK hands
    /// that receipt to that event and to no other, so mapping each event on its own gave a galley
    /// of "sent" ticks with one "read" at the bottom — which is what a receipt means, but not what
    /// it says, and the screen was reporting the protocol instead of the conversation.
    ///
    /// Receipts are monotonic: reading event N is reading everything before it. So the last event
    /// carrying a receipt is a watermark, and everything of yours above it is read too — and so is
    /// the moment on it, which comes down with the fact rather than staying behind. The receipt
    /// reports "read this far by 14:03", which is exactly true of the message it names and an upper
    /// bound for every message above: read then or read earlier, and 14:03 is the only moment
    /// anybody reported. The alternative was showing the time under one message out of fifteen that
    /// were all equally read, which answers "when?" by pointing somewhere else.
    ///
    /// The watermark comes in two forms, and the second is the whole reason this takes a parameter.
    /// `.read` on one of your own messages is the easy case: the receipt landed on something you
    /// said. But the event somebody last read is far more often *not* yours — they read up to their
    /// own reply — and it may not be a row at all, because this app drops most of what the SDK
    /// holds. Such a receipt used to vanish along with the event carrying it, and every message
    /// above it then sat on one tick for good: the exact complaint, "they have plainly read it and
    /// it still says sent". `readUpTo` is that watermark, counted in rows by `rows(from:)`, which
    /// is the only place that can still see those events before they are thrown away.
    ///
    /// Not private: `ReadReceiptTests` drives it directly, which is the only way to test it —
    /// a real `EventTimelineItem` cannot be built outside the SDK. Hence the default: a test about
    /// the own-message watermark is saying nothing about the other one.
    static func withReadPropagated(_ rows: [TimelineRow],
                                   readUpTo readPrefix: Int = 0,
                                   at readPrefixAt: Date? = nil) -> [TimelineRow] {
        var rows = rows
        var seenRead = false
        var marked = false

        // The moment to hand to a message that was read without a receipt of its own: the nearest
        // receipt that still covers it. Walking from the newest downwards, that is simply the last
        // receipt this loop went past — every step back is a step to an older message, and the
        // receipt it meets next is a tighter bound than the one before.
        //
        // Tighter, and never wrong in the other direction. A receipt says "I had read this far by
        // 14:03", so 14:03 is the answer for the message it names and an upper bound for every
        // message above it — read then, or read earlier. The menu says the moment the reader
        // reported; it is the only moment anybody reported.
        var moment: Date?

        // Downwards from the newest, because the watermark is below the messages it settles.
        for index in rows.indices.reversed() {
            guard case var .message(message) = rows[index], message.isOwn else { continue }

            // Stepping into the stretch the foreign watermark covers — see `readUpTo`.
            if index < readPrefix, moment == nil { moment = readPrefixAt }

            if message.delivery == .read {
                seenRead = true
                // Its own receipt is the tightest bound there is for everything above it.
                moment = message.readAt ?? moment
            } else if message.delivery == .sent, seenRead || index < readPrefix {
                message.delivery = .read
            }

            if message.delivery == .read {
                message.readAt = message.readAt ?? moment

                // The mark goes on the newest message of yours that has been read — see
                // `Message.carriesReadMark`. Newest *read*, not simply newest: a message still in
                // flight underneath it would otherwise take the mark away from a conversation that
                // has plainly been read, which is the fault this whole file is about.
                if !marked {
                    message.carriesReadMark = true
                    marked = true
                }
            }

            rows[index] = .message(message)
        }

        return rows
    }

    /// Drops the date headers that have nothing under them.
    ///
    /// "Вчера" was appearing over a day on which nobody said anything, and the reason is that the
    /// SDK and this app do not agree about what a day *contains*. The SDK puts a date divider
    /// before every event it holds, and it holds a great many events this app deliberately never
    /// shows: somebody changing their picture, a power level being adjusted, a topic edit, an
    /// event so exotic the SDK could not parse it either. Every one of those is dropped above —
    /// correctly, a conversation is not an audit log — and the header that was put up to introduce
    /// them stayed behind, announcing a day whose entire contents had just been thrown away.
    ///
    /// So the last word on a divider belongs to this pass, after the dropping is finished, rather
    /// than to the moment it arrives, when what follows it is not yet known. A divider survives if
    /// there is any row under it before the next divider — a message, or a grey line about
    /// something that happened, which is a real thing to have happened on a day. It does not
    /// survive being the last row in the list, and that is the same rule and not an exception: a
    /// header at the very bottom is a promise of messages that are not there.
    ///
    /// This also settles two dividers in a row, which is the same fault wearing a different shape
    /// and arrives at a page boundary while history is being fetched.
    /// Not private: `DayDividerTests` drives it directly, which is the only way to test it —
    /// building fake `TimelineItem`s means building SDK types this app is not allowed to invent.
    static func withoutEmptyDays(_ rows: [TimelineRow]) -> [TimelineRow] {
        rows.enumerated().filter { index, row in
            guard case .dayDivider = row else { return true }

            // The very next row, and nothing further. What a day contains is what lies between
            // its header and the next one, so the row immediately below is the whole question: a
            // message or a grey line means the day happened, and another header — or the end of
            // the list — means it did not.
            //
            // "Is there any content *anywhere* below" was the first way this was written, and it
            // is wrong in the exact case that was reported: yesterday's header, today's header,
            // today's messages. Yesterday can see today's messages from where it stands, and kept
            // itself on that basis. The tests caught it.
            guard rows.indices.contains(index + 1) else { return false }
            if case .dayDivider = rows[index + 1] { return false }
            return true
        }
        .map(\.element)
    }

    /// Adds a room event, pooling it into the one above where they say the same kind of thing.
    ///
    /// The pooled line keeps the *first* event's identity, so a second person joining grows the
    /// line that is already on screen instead of replacing it with a different row — which
    /// would make SwiftUI animate a removal and an insertion where the reader should simply see
    /// a name appear.
    private static func append(_ event: RoomEvent, to rows: inout [TimelineRow]) {
        if case let .event(previous)? = rows.last,
           let merged = previous.kind.merged(with: event.kind) {
            rows[rows.count - 1] = .event(RoomEvent(id: previous.id,
                                                    kind: merged,
                                                    timestamp: event.timestamp))
            return
        }

        rows.append(.event(event))
    }

    private static func message(from event: EventTimelineItem,
                                ownUserID: String) -> Message? {
        guard let kind = kind(from: event.content, ownUserID: ownUserID) else { return nil }

        let (name, avatar) = profile(from: event.senderProfile, fallback: event.sender)
        let id = identifier(for: event.eventOrTransactionId)

        var message = Message(id: id,
                       kind: kind,
                       senderID: event.sender,
                       senderName: name,
                       senderAvatarURL: avatar,
                       isOwn: event.isOwn,
                       timestamp: MessagePreview.date(from: event.timestamp),
                       delivery: event.isOwn ? delivery(for: event, ownUserID: ownUserID) : nil,
                       readAt: event.isOwn ? readAt(of: event, ownUserID: ownUserID) : nil,
                       isEdited: isEdited(event.content),
                       replyTo: replyPreview(from: event.content),
                       reactions: reactions(from: event.content, ownUserID: ownUserID),
                       deletedAt: kind == .deleted ? redaction(of: event) : nil,
                       mentionedUserIDs: mentionedUserIDs(from: event.content),
                       formattedBody: formattedBody(from: event.content),
                       forwardedFrom: forwardOrigin(of: event, kind: kind),
                       uploadProgress: event.isOwn ? uploadProgress(of: event.localSendState) : nil)
        if case let .msgLike(msgLike) = event.content {
            message.threadRootID = msgLike.threadRoot
            message.thread = msgLike.threadSummary.map(threadPreview)
        }
        return message
    }

    /// "3 answers", and the newest — what is drawn under a message answered in a thread.
    private static func threadPreview(_ summary: ThreadSummary) -> ThreadSummaryPreview {
        var sender: String?
        var text: String?
        if case let .ready(content, senderID, senderProfile, _, _) = summary.latestEvent() {
            sender = profile(from: senderProfile, fallback: senderID).0
            text = MessagePreview.text(for: content)
        }
        return ThreadSummaryPreview(replies: Int(summary.numReplies()), latestSender: sender, latestText: text)
    }

    /// The `m.forwarded` the event carries, if it is a forward — see `ForwardOrigin`. Read off the
    /// event's own JSON, the one place the SDK keeps a field it has no name for, and only for the
    /// kinds that can be forwarded at all; once per event, see `Forwarded.origin(eventID:json:)`.
    private static func forwardOrigin(of event: EventTimelineItem, kind: MessageKind) -> ForwardOrigin? {
        switch kind {
        case .text, .notice, .emote, .image, .video, .file: break
        default: return nil
        }
        guard case let .eventId(eventID) = event.eventOrTransactionId else { return nil }
        return Forwarded.origin(eventID: eventID) { event.lazyProvider.debugInfo().originalJson }
    }

    /// How far an attachment of ours has got on its way up — see `Message.uploadProgress`.
    ///
    /// Nil until the SDK has a total to divide by: a ring that starts at an invented zero and then
    /// leaps is worse than one that appears when there is something true to draw.
    static func uploadProgress(of state: EventSendState?) -> Double? {
        guard case let .notSentYet(upload?)? = state, upload.progress.total > 0 else { return nil }
        return min(1, Double(upload.progress.current) / Double(upload.progress.total))
    }

    /// The IDs an event says it mentions — its `m.mentions` set. Only message events carry them;
    /// everything else has nobody to mention.
    private static func mentionedUserIDs(from content: TimelineItemContent) -> [String] {
        guard case let .msgLike(msgLike) = content,
              case let .message(message) = msgLike.kind
        else { return [] }
        return message.mentions?.userIds ?? []
    }

    // MARK: - Room events

    /// The things that happen to a room rather than in it.
    ///
    /// Everything the SDK reports and this app has nothing to say about — power levels, join
    /// rules, server ACLs, an event it could not even parse — comes back nil and is dropped.
    /// That is not laziness: a conversation is not an audit log, and a line reading "history
    /// visibility changed to shared" is protocol vocabulary leaking into somebody's chat.
    ///
    /// An avatar-only profile change is dropped too, and that one is a judgement call worth
    /// naming. A person changing their picture is a fact the room genuinely does not need told
    /// about — you can see their new face on their next message — and rooms where a few people
    /// fiddle with their avatars would otherwise fill with notes about it.
    private static func roomEvent(from event: EventTimelineItem) -> RoomEvent? {
        guard let kind = roomEventKind(from: event.content, sender: event.sender) else { return nil }

        return RoomEvent(id: identifier(for: event.eventOrTransactionId),
                         kind: kind,
                         timestamp: MessagePreview.date(from: event.timestamp),
                         actorID: event.sender)
    }

    private static func roomEventKind(from content: TimelineItemContent, sender: String) -> RoomEventKind? {
        switch content {
        case let .roomMembership(userId, userDisplayName, change, _):
            // The name the room knows them by, and their Matrix ID when it knows none. A line
            // reading "@alice:matrix.org joined" is worse than nothing to nobody: it is exactly
            // what somebody without a display name looks like everywhere else in the app.
            let who = RoomEventPerson(userID: userId, name: userDisplayName ?? userId)

            return switch change {
            case .joined, .invitationAccepted, .knockAccepted: .joined([who])
            case .left, .invitationRejected, .knockRetracted: .left([who])
            case .invited: .invited([who])
            case .kicked, .invitationRevoked, .knockDenied: .removed([who])
            case .banned, .kickedAndBanned: .banned([who])
            default: nil
            }

        case let .profileChange(displayName, prevDisplayName, _, _):
            // Only a change of *name*, and only one where both halves are known: "somebody is
            // now Аня" and "Аня is now somebody" are not sentences worth ruling a line across
            // a conversation for.
            guard let displayName, let prevDisplayName, displayName != prevDisplayName else { return nil }
            return .renamedThemselves(from: prevDisplayName, to: displayName)

        case let .state(_, state):
            return switch state {
            case let .roomName(name): name.map { .roomRenamed($0) }
            case .roomTopic: .roomTopicChanged
            case .roomAvatar: .roomPictureChanged
            case .roomCreate: .roomCreated
            case .roomEncryption: .encryptionEnabled
            default: nil
            }

        default:
            return nil
        }
    }

    // MARK: - Replies

    /// The replies whose originals the SDK is holding nothing for — the messages that would
    /// otherwise be drawn as "Message unavailable".
    ///
    /// `.unavailable` is not the SDK saying it looked and could not find the message. It is the
    /// SDK saying **nobody has asked it to look**: the details of a replied-to event are fetched
    /// on demand, by `Timeline.fetchDetailsForEvent`, and nothing in this app was calling it. So
    /// every reply to a message that was not already on screen — which is every reply to anything
    /// old — came up as a quote of nothing, and stayed that way even once the original had been
    /// paginated back in, because the item was never rebuilt. See `TimelineStore.fetchReplyDetails`.
    ///
    /// The ID wanted is the *reply's* own, not the one it is answering: the SDK is being asked to
    /// finish an item it already holds.
    static func repliesMissingTheirOriginal(in items: [TimelineItem]) -> [String] {
        items.compactMap { $0.asEvent().flatMap(unresolvedReply(of:)) }
    }

    /// One item's half of `repliesMissingTheirOriginal`.
    private static func unresolvedReply(of event: EventTimelineItem) -> String? {
        guard case let .eventId(eventID) = event.eventOrTransactionId,
              case let .msgLike(msgLike) = event.content,
              let details = msgLike.inReplyTo else { return nil }

        // `.pending` is the SDK already fetching it. Asking again would be asking twice.
        switch details.event() {
        case .unavailable: return eventID
        case .ready, .pending, .error: return nil
        }
    }

    /// The message being answered, as the SDK resolved it.
    ///
    /// It does the resolving, and that matters: the original may be a thousand events up the
    /// conversation and not loaded at all, and nothing here goes and fetches it. What comes
    /// back is either the message, a promise that it is on its way, or an admission that it
    /// could not be found — and all three are said out loud rather than papered over, because
    /// a quote that silently shows the wrong thing is worse than one that says it does not know.
    private static func replyPreview(from content: TimelineItemContent) -> ReplyPreview? {
        guard case let .msgLike(msgLike) = content,
              let details = msgLike.inReplyTo else { return nil }

        let eventID = details.eventId()

        switch details.event() {
        case let .ready(content, sender, senderProfile, _, _):
            let (name, _) = profile(from: senderProfile, fallback: sender)
            let text = MessagePreview.text(for: content) ?? String(core: CoreStrings.Reply.unavailable)
            return ReplyPreview(eventID: eventID, senderName: name, senderID: sender, text: text)

        case .pending:
            return ReplyPreview(eventID: eventID,
                                senderName: nil,
                                text: String(core: CoreStrings.Reply.loading))

        case .unavailable, .error:
            return ReplyPreview(eventID: eventID,
                                senderName: nil,
                                text: String(core: CoreStrings.Reply.unavailable))
        }
    }

    // MARK: - Redaction

    /// When a message was taken back.
    ///
    /// The SDK's own vocabulary does not have this: `MsgLikeKind.redacted` carries nothing at
    /// all, and `EventTimelineItem.timestamp` is still the moment the message was *sent* —
    /// which is right, and is why it cannot answer this question. The one place the fact
    /// survives is the event as the homeserver sent it: a redacted event arrives with the
    /// redaction that killed it attached, under `unsigned.redacted_because`, and that is a
    /// shape the Matrix spec fixes rather than something the SDK is free to change.
    ///
    /// So it is read from the raw JSON — read, not reconstructed. Every step of the way down
    /// is optional, and a homeserver that leaves the redaction out simply means a message
    /// whose menu says when it was sent and nothing about when it went. That is a row missing,
    /// not a wrong date, which is the only acceptable way for this to fail.
    private static func redaction(of event: EventTimelineItem) -> Date? {
        guard let json = event.lazyProvider.debugInfo().originalJson,
              let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let unsigned = object["unsigned"] as? [String: Any],
              let because = unsigned["redacted_because"] as? [String: Any],
              let milliseconds = because["origin_server_ts"] as? UInt64 else { return nil }

        return MessagePreview.date(from: milliseconds)
    }

    // MARK: - Reactions

    /// The emoji under a message, oldest first.
    ///
    /// Ordered by when each emoji was *first* used rather than by how popular it has
    /// become, so a pill never jumps sideways under the user's thumb because someone
    /// else pressed a different one. An emoji nobody has left is dropped: the SDK can
    /// report a reaction with no senders once the last person takes theirs back, and an
    /// empty pill reading "0" would be a lie about a thing that is no longer there.
    private static func reactions(from content: TimelineItemContent, ownUserID: String) -> [MessageReaction] {
        guard case let .msgLike(msgLike) = content else { return [] }

        return msgLike.reactions
            .filter { !$0.senders.isEmpty }
            .sorted { first, second in
                let firstSeen = first.senders.map(\.timestamp).min() ?? 0
                let secondSeen = second.senders.map(\.timestamp).min() ?? 0
                return firstSeen < secondSeen
            }
            .map { reaction in
                MessageReaction(key: reaction.key,
                                count: reaction.senders.count,
                                isMine: reaction.senders.contains { $0.senderId == ownUserID },
                                senders: reaction.senders.sorted { $0.timestamp < $1.timestamp }.map(\.senderId))
            }
    }

    // MARK: - Content

    private static func kind(from content: TimelineItemContent, ownUserID: String) -> MessageKind? {
        guard case let .msgLike(msgLike) = content else { return nil }

        switch msgLike.kind {
        case let .message(message):
            return kind(from: message)
        case let .sticker(body, info, source):
            // A sticker is not an `m.room.message` at all — it is an event type of its own,
            // which is why it arrives here beside `.message` rather than inside it, and why
            // it has no `msgType` to look at.
            //
            // The body is the sender's description of it — an emoji, or a word like "hug" —
            // and it is carried as the caption because that is the one place it can still be
            // read: nothing is drawn under a sticker, but VoiceOver has to say *which* one.
            return .sticker(Attachment(source: source,
                                       thumbnailSource: info.thumbnailSource,
                                       filename: "sticker",
                                       caption: body.isEmpty ? nil : body,
                                       width: info.width.map(Int.init),
                                       height: info.height.map(Int.init),
                                       duration: nil,
                                       mimeType: info.mimetype,
                                       blurhash: info.blurhash))
        case let .poll(question, kind, maxSelections, answers, votes, endTime, _):
            return .poll(Poll(question: question,
                              kind: kind,
                              maxSelections: maxSelections,
                              answers: answers,
                              votes: votes,
                              isEnded: endTime != nil,
                              ownUserID: ownUserID))
        case let .liveLocation(content):
            // A live share: the SDK has gathered its points under the event that started it, and the
            // last of them is where the person is. Before the first point the map has nothing to
            // stand on, and says so — see `Location.LiveSpan.hasPosition`.
            let last = content.locations.last
            var location = last.flatMap { Location(geoURI: $0.geoUri, name: content.description) }
                ?? Location(latitude: 0, longitude: 0, name: content.description)
            let started = MessagePreview.date(from: content.ts)
            location.live = Location.LiveSpan(isLive: content.isLive,
                                              until: started.addingTimeInterval(TimeInterval(content.timeoutMs) / 1000),
                                              updatedAt: last.map { MessagePreview.date(from: $0.ts) })
            return .location(location)
        case .redacted:
            return .deleted
        case .unableToDecrypt:
            return .unreadable
        default:
            return .unsupported
        }
    }

    /// The HTML a text, emote or notice carries beside its plain body — or a caption beside its
    /// plain one — when it carries HTML.
    private static func formattedBody(from content: TimelineItemContent) -> String? {
        guard case let .msgLike(msgLike) = content, case let .message(message) = msgLike.kind else { return nil }
        let formatted: FormattedBody?
        switch message.msgType {
        case let .text(content): formatted = content.formatted
        case let .emote(content): formatted = content.formatted
        case let .notice(content): formatted = content.formatted
        // A caption's HTML, which is drawn under the picture the same way — see `MediaCaption`.
        case let .image(content): formatted = content.formattedCaption
        case let .video(content): formatted = content.formattedCaption
        case let .audio(content): formatted = content.formattedCaption
        case let .file(content): formatted = content.formattedCaption
        default: formatted = nil
        }
        guard let formatted, case .html = formatted.format else { return nil }
        return formatted.body
    }

    private static func kind(from message: MessageContent) -> MessageKind {
        switch message.msgType {
        case let .text(content):
            return .text(content.body)
        case let .emote(content):
            return .emote(content.body)
        case let .notice(content):
            return .notice(content.body)

        case let .image(content):
            let attachment = Attachment(source: content.source,
                                        thumbnailSource: content.info?.thumbnailSource,
                                        filename: content.filename,
                                        caption: content.caption,
                                        width: content.info?.width.map(Int.init),
                                        height: content.info?.height.map(Int.init),
                                        duration: nil,
                                        mimeType: content.info?.mimetype,
                                        blurhash: content.info?.blurhash)
            // A WebP is a sticker however it came: in an encrypted room this app sends one as an
            // encrypted image, because a real `m.sticker` would go up unencrypted — see
            // `StickerPicture`.
            return StickerPicture.isSticker(mimeType: content.info?.mimetype, filename: content.filename) ? .sticker(attachment)
                                                                              : .image(attachment)

        case let .video(content):
            let attachment = Attachment(source: content.source,
                                        thumbnailSource: content.info?.thumbnailSource,
                                        filename: content.filename,
                                        caption: content.caption,
                                        width: content.info?.width.map(Int.init),
                                        height: content.info?.height.map(Int.init),
                                        duration: content.info?.duration,
                                        mimeType: content.info?.mimetype,
                                        blurhash: content.info?.blurhash)
            // Square and short means it was recorded as a round video message.
            return VideoNote.isVideoNote(content) ? .videoNote(attachment) : .video(attachment)

        case let .audio(content):
            let attachment = Attachment(source: content.source,
                                        thumbnailSource: nil,
                                        filename: content.filename,
                                        caption: content.caption,
                                        width: nil,
                                        height: nil,
                                        duration: content.info?.duration,
                                        mimeType: content.info?.mimetype,
                                        blurhash: nil)
            // `voice` is the marker other Matrix clients set on spoken messages.
            if content.voice != nil {
                // The wire format is 0...`waveformScale` per sample; the UI wants 0...1 so it can
                // just multiply by a bar height.
                let waveform = (content.audio?.waveform ?? []).map { Float($0) / Float(waveformScale) }
                return .voice(attachment, waveform: waveform)
            }
            return .audio(attachment)

        case let .location(content):
            // A `geo:` URI this app cannot read is not a location — see `Location.init(geoURI:)`.
            // It becomes an unsupported message rather than a pin in the middle of the Atlantic.
            guard let location = Location(geoURI: content.geoUri, name: content.description) else {
                return .unsupported
            }
            return .location(location)

        case let .file(content):
            return .file(Attachment(source: content.source,
                                    thumbnailSource: content.info?.thumbnailSource,
                                    filename: content.filename,
                                    caption: content.caption,
                                    width: nil,
                                    height: nil,
                                    duration: nil,
                                    mimeType: content.info?.mimetype,
                                    blurhash: nil))

        default:
            return .unsupported
        }
    }

    private static func isEdited(_ content: TimelineItemContent) -> Bool {
        guard case let .msgLike(msgLike) = content,
              case let .message(message) = msgLike.kind else { return false }
        return message.isEdited
    }

    // MARK: - Sender and delivery

    private static func profile(from details: ProfileDetails, fallback userID: String) -> (name: String, avatar: String?) {
        if case let .ready(displayName, _, avatarURL) = details {
            return (displayName ?? userID, avatarURL)
        }
        // Before the profile loads, the user ID is the honest thing to show.
        return (userID, nil)
    }

    /// Whether anybody *else* has reported reading this event.
    ///
    /// The SDK is believed to leave our own receipt out of this map, and every reading of it here
    /// rests on that: our own receipt sits on the newest event we have looked at, so counting it
    /// would mark the whole conversation read the moment we opened the room. The belief costs one
    /// comparison to stop resting on, so it is not rested on.
    private static func hasForeignReceipt(_ event: EventTimelineItem, ownUserID: String) -> Bool {
        event.readReceipts.keys.contains { $0 != ownUserID }
    }

    private static func delivery(for event: EventTimelineItem, ownUserID: String) -> DeliveryStatus {
        switch event.localSendState {
        case .notSentYet:
            return .sending
        case .sendingFailed(_, isRecoverable: true):
            // Still on its way, and that is the truth rather than a kindness. A recoverable failure
            // is the SDK saying the request did not get through — the network went, the server timed
            // out — and that it has *paused the room's queue* rather than given up on the message.
            // Nothing about the message is wrong. The queue is started again when sync comes back
            // and, while sync is running, on a backoff of its own (`SendQueueRecovery`), and the
            // message goes with it.
            //
            // It used to be drawn as a failure, which is the one thing Telegram is careful never to
            // do: write a message in a lift and it sits there with a clock until there is a network,
            // and then it goes. Here it got the red badge — about a message that was going to be sent
            // anyway, a few seconds later, with nobody pressing anything. And people did press:
            // "Send again" on a message already going, "Discard" on one that would have gone.
            return .sending
        case let .sendingFailed(error, isRecoverable: false):
            // Parked: the queue has stepped round this one message and will not try it again by
            // itself. That is a real failure, and its reason is the fix — `SendFailure.canRetry`
            // says which of them a second press can clear.
            return .failed(reason(for: error))
        case .sent, .none:
            // Sent, and possibly read. A receipt from anyone but us means read.
            return hasForeignReceipt(event, ownUserID: ownUserID) ? .read : .sent
        }
    }

    /// When the message was first read by somebody else — see `Message.readAt`.
    ///
    /// Our own receipt is dropped — see `hasForeignReceipt` — which is what makes the set usable
    /// as an answer to "has anybody read this". The earliest of them is the moment the message
    /// stopped being unread, and a receipt without a timestamp contributes nothing rather than
    /// being counted as "now".
    private static func readAt(of event: EventTimelineItem, ownUserID: String) -> Date? {
        let stamps = event.readReceipts
            .filter { $0.key != ownUserID }
            .values
            .compactMap(\.timestamp)
        guard let first = stamps.min() else { return nil }
        return MessagePreview.date(from: first)
    }

    /// The SDK's reason, turned into one the user can act on.
    ///
    /// `genericApiError` carries the homeserver's own words, and they stay here: they are
    /// written in English for an administrator, and the user gets a sentence instead.
    private static func reason(for error: QueueWedgeError) -> SendFailure {
        switch error {
        case .insecureDevices: .insecureDevices
        case .identityViolations: .identityChanged
        case .crossVerificationRequired: .verificationRequired
        case .missingMediaContent: .missingMedia
        case .invalidMimeType: .unsupportedFileType
        case .genericApiError: .server
        }
    }

    /// Not private: `TimelineStore` needs it to find the SDK item behind a `Message.id`
    /// when the user asks to send a stuck message again.
    static func identifier(for id: EventOrTransactionId) -> String {
        switch id {
        case let .eventId(eventId): eventId
        case let .transactionId(transactionId): transactionId
        }
    }
}
