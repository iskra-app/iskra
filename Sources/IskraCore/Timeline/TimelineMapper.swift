import Foundation
import MatrixRustSDK

/// Turns the SDK's timeline items into the value types the UI renders.
///
/// This is the only place that knows about `MsgLikeKind`, `EventSendState` and the
/// rest of the SDK's vocabulary. Everything above it deals in `Message`s.
enum TimelineMapper {
    static func rows(from items: [TimelineItem]) -> [TimelineRow] {
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

            guard let event = item.asEvent(), var message = message(from: event) else { continue }

            // Group consecutive messages from the same person, iMessage-style: only
            // the first one in a run carries a name and an avatar.
            if let previous,
               previous.senderID == message.senderID,
               message.timestamp.timeIntervalSince(previous.timestamp) < 300 {
                message.isContinuation = true
            }

            rows.append(.message(message))
            previous = message
        }

        return rows
    }

    private static func message(from event: EventTimelineItem) -> Message? {
        guard let kind = kind(from: event.content) else { return nil }

        let (name, avatar) = profile(from: event.senderProfile, fallback: event.sender)

        return Message(id: identifier(for: event.eventOrTransactionId),
                       kind: kind,
                       senderID: event.sender,
                       senderName: name,
                       senderAvatarURL: avatar,
                       isOwn: event.isOwn,
                       timestamp: MessagePreview.date(from: event.timestamp),
                       delivery: event.isOwn ? delivery(for: event) : nil,
                       isEdited: isEdited(event.content))
    }

    // MARK: - Content

    private static func kind(from content: TimelineItemContent) -> MessageKind? {
        guard case let .msgLike(msgLike) = content else { return nil }

        switch msgLike.kind {
        case let .message(message):
            return kind(from: message)
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
                                     filename: content.filename,
                                     caption: content.caption,
                                     width: content.info?.width.map(Int.init),
                                     height: content.info?.height.map(Int.init),
                                     duration: nil,
                                     blurhash: content.info?.blurhash))

        case let .video(content):
            let attachment = Attachment(source: content.source,
                                        filename: content.filename,
                                        caption: content.caption,
                                        width: content.info?.width.map(Int.init),
                                        height: content.info?.height.map(Int.init),
                                        duration: content.info?.duration,
                                        blurhash: content.info?.blurhash)
            // Square and short means it was recorded as a round video message.
            return VideoNote.isVideoNote(content) ? .videoNote(attachment) : .video(attachment)

        case let .audio(content):
            let attachment = Attachment(source: content.source,
                                        filename: content.filename,
                                        caption: content.caption,
                                        width: nil,
                                        height: nil,
                                        duration: content.info?.duration,
                                        blurhash: nil)
            // `voice` is the marker other Matrix clients set on spoken messages.
            if content.voice != nil {
                // The wire format is 0...1024 per sample; the UI wants 0...1 so it can
                // just multiply by a bar height.
                let waveform = (content.audio?.waveform ?? []).map { Float($0) / 1024 }
                return .voice(attachment, waveform: waveform)
            }
            return .audio(attachment)

        case let .file(content):
            return .file(Attachment(source: content.source,
                                    filename: content.filename,
                                    caption: content.caption,
                                    width: nil,
                                    height: nil,
                                    duration: nil,
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
        case .sendingFailed:
            return .failed
        case .sent, .none:
            // Sent, and possibly read. A receipt from anyone but us means read;
            // the SDK does not include our own receipt here.
            return event.readReceipts.isEmpty ? .sent : .read
        }
    }

    private static func identifier(for id: EventOrTransactionId) -> String {
        switch id {
        case let .eventId(eventId): eventId
        case let .transactionId(transactionId): transactionId
        }
    }
}
