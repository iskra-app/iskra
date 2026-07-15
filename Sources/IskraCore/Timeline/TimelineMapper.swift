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

    /// `ownUserID` is here for one reason: a reaction pill has to know whether *you* are
    /// among the people who left it, because pressing it again takes it back. The SDK
    /// tells us who reacted, not whether one of them is us.
    ///
    /// `unsent` is the reactions of ours that never left the send queue. The SDK goes on
    /// reporting them as though they had, so they are subtracted here — see `UnsentReactions`.
    static func rows(from items: [TimelineItem],
                     ownUserID: String,
                     unsent: UnsentReactions = UnsentReactions()) -> [TimelineRow] {
        var rows: [TimelineRow] = []
        rows.reserveCapacity(items.count)

        var previous: Message?

        for item in items {
            if let virtual = item.asVirtual() {
                if case let .dateDivider(timestamp) = virtual {
                    let date = MessagePreview.date(from: timestamp)
                    rows.append(.dayDivider(DayDivider(id: "divider-\(timestamp)", date: date)))
                    // A date divider breaks the visual grouping.
                    previous = nil
                }
                continue
            }

            guard let event = item.asEvent() else { continue }

            // Something that happened rather than something somebody said. It goes in as a
            // grey line — and it may not go in at all, because two people joining one after
            // the other is one line and not two. See `append`.
            if let roomEvent = roomEvent(from: event) {
                append(roomEvent, to: &rows)
                // A note across the conversation breaks a run of messages: the one below it
                // is no longer "the same person still talking".
                previous = nil
                continue
            }

            guard var message = message(from: event, ownUserID: ownUserID, unsent: unsent) else { continue }

            // Group consecutive messages from the same person, iMessage-style: only
            // the first one in a run carries a name and an avatar.
            if let previous,
               previous.senderID == message.senderID,
               message.timestamp.timeIntervalSince(previous.timestamp) < runWindow {
                message.isContinuation = true
            }

            rows.append(.message(message))
            previous = message
        }

        return withoutEmptyDays(rows)
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
                                ownUserID: String,
                                unsent: UnsentReactions) -> Message? {
        guard let kind = kind(from: event.content) else { return nil }

        let (name, avatar) = profile(from: event.senderProfile, fallback: event.sender)
        let id = identifier(for: event.eventOrTransactionId)

        return Message(id: id,
                       kind: kind,
                       senderID: event.sender,
                       senderName: name,
                       senderAvatarURL: avatar,
                       isOwn: event.isOwn,
                       timestamp: MessagePreview.date(from: event.timestamp),
                       delivery: event.isOwn ? delivery(for: event) : nil,
                       isEdited: isEdited(event.content),
                       replyTo: replyPreview(from: event.content),
                       reactions: unsent.applied(to: reactions(from: event.content, ownUserID: ownUserID),
                                                 messageID: id),
                       deletedAt: kind == .deleted ? redaction(of: event) : nil,
                       mentionedUserIDs: mentionedUserIDs(from: event.content))
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
                         timestamp: MessagePreview.date(from: event.timestamp))
    }

    private static func roomEventKind(from content: TimelineItemContent, sender: String) -> RoomEventKind? {
        switch content {
        case let .roomMembership(userId, userDisplayName, change, _):
            // The name the room knows them by, and their Matrix ID when it knows none. A line
            // reading "@alice:matrix.org joined" is worse than nothing to nobody: it is exactly
            // what somebody without a display name looks like everywhere else in the app.
            let who = userDisplayName ?? userId

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
        items.compactMap { item -> String? in
            guard let event = item.asEvent(),
                  case let .eventId(eventID) = event.eventOrTransactionId,
                  case let .msgLike(msgLike) = event.content,
                  let details = msgLike.inReplyTo else { return nil }

            // `.pending` is the SDK already fetching it. Asking again would be asking twice.
            switch details.event() {
            case .unavailable: return eventID
            case .ready, .pending, .error: return nil
            }
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
            return ReplyPreview(eventID: eventID, senderName: name, text: text)

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
                                isMine: reaction.senders.contains { $0.senderId == ownUserID })
            }
    }

    // MARK: - Content

    private static func kind(from content: TimelineItemContent) -> MessageKind? {
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
        case .redacted:
            return .deleted
        case .unableToDecrypt:
            return .unreadable
        default:
            return .unsupported
        }
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
            return .image(Attachment(source: content.source,
                                     thumbnailSource: content.info?.thumbnailSource,
                                     filename: content.filename,
                                     caption: content.caption,
                                     width: content.info?.width.map(Int.init),
                                     height: content.info?.height.map(Int.init),
                                     duration: nil,
                                     mimeType: content.info?.mimetype,
                                     blurhash: content.info?.blurhash))

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

    private static func delivery(for event: EventTimelineItem) -> DeliveryStatus {
        switch event.localSendState {
        case .notSentYet:
            return .sending
        case let .sendingFailed(error, _):
            // The SDK's `isRecoverable` is dropped on purpose: it describes what the *queue*
            // did, not whether the user can get the message moving. See `SendFailure.canRetry`.
            return .failed(reason(for: error))
        case .sent, .none:
            // Sent, and possibly read. A receipt from anyone but us means read;
            // the SDK does not include our own receipt here.
            return event.readReceipts.isEmpty ? .sent : .read
        }
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
