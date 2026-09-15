import Foundation
import MatrixRustSDK

/// Turns what the SDK found for a push into the words a person reads.
///
/// The same division as `TimelineMapper`, and made for the same reason: `PushDecoder` has
/// to open a store, restore a session and reach the network, none of which a test can do —
/// while *this*, which decides every word that lands on the lock screen, is a pure function
/// of an SDK value and can be pinned exactly. See `PushTests`.
enum PushMapper {
    static func outcome(for status: NotificationStatus,
                        roomID: String,
                        eventID: String) -> PushOutcome {
        switch status {
        case let .event(item):
            return outcome(for: item, roomID: roomID, eventID: eventID)

        case .eventFilteredOut:
            return .silence(.filteredOut)

        case .eventRedacted:
            return .silence(.redacted)

        case .eventNotFound:
            // Not silence. The server told us an event exists and then could not produce it,
            // and we have no grounds to decide it was unimportant — so this is a failure, and
            // the extension leaves the server's own text on screen rather than swallowing a
            // message that really did arrive.
            return .failed("the event could not be found")
        }
    }

    static func outcome(for item: NotificationItem,
                        roomID: String,
                        eventID: String) -> PushOutcome {
        let room = item.roomInfo
        let senderName = item.senderInfo.displayName ?? ""
        let isNoisy = item.isNoisy ?? false

        let roomName = room.displayName.isEmpty
            ? String(core: CoreStrings.Room.untitled)
            : room.displayName

        switch item.event {
        case let .invite(sender):
            // An invitation is the one push that is not a message, and the only one where the
            // sender's name is the sentence rather than a label above it. `senderInfo` carries
            // the name they chose; the raw Matrix ID is what is left when they have not chosen
            // one, and a bare "@anya:matrix.org invites you" is still better than a blank.
            return .show(PushNotification(roomID: roomID,
                                          eventID: eventID,
                                          title: roomName,
                                          sender: nil,
                                          body: String(localized: CoreStrings.Push.invite(
                                              senderName.isEmpty ? sender : senderName)),
                                          isNoisy: isNoisy,
                                          personName: senderName.isEmpty ? sender : senderName,
                                          personID: sender,
                                          avatarURL: item.senderInfo.avatarUrl))

        case let .timeline(event):
            guard let content = try? event.content(),
                  case let .messageLike(messageLike) = content,
                  let body = text(for: messageLike) else {
                return .silence(.notWorthWaking)
            }

            let who = attribution(roomName: roomName,
                                  senderName: senderName,
                                  isDirect: room.isDm,
                                  localName: LocalNames.name(for: roomID))
            return .show(PushNotification(roomID: roomID,
                                          eventID: eventID,
                                          title: who.title,
                                          sender: who.sender,
                                          body: body,
                                          isNoisy: isNoisy,
                                          // Deliberately not `who.sender`, which is nil in a
                                          // direct chat. Who spoke and what goes on the second
                                          // line are two questions, and only one of them has an
                                          // answer that depends on the room.
                                          personName: senderName.isEmpty ? event.senderId() : senderName,
                                          personID: event.senderId(),
                                          avatarURL: item.senderInfo.avatarUrl))
        }
    }

    /// Strips a notification down to "New message" when the app is locked, keeping only what it
    /// needs to open the right room once the user is past the lock. Pure, so the rule — content shows
    /// only when unlocked — is pinned in a test rather than trusted to a device.
    ///
    /// An invitation is redacted too: "Аня invites you" names a person, which is exactly what a
    /// locked phone should not put on its screen. Silences and failures pass through untouched —
    /// there is nothing shown to hide.
    static func redactIfLocked(_ outcome: PushOutcome, locked: Bool) -> PushOutcome {
        guard locked, case let .show(notification) = outcome else { return outcome }
        return .show(PushNotification(roomID: notification.roomID,
                                      eventID: notification.eventID,
                                      title: String(core: CoreStrings.Push.hiddenTitle),
                                      sender: nil,
                                      body: String(core: CoreStrings.Push.hiddenBody),
                                      isNoisy: notification.isNoisy))
    }

    /// Who the notification is *from* — which is not quite the same question as who sent it.
    ///
    /// In a group the two lines are a room and a person, and both are needed: "Кухня" tells
    /// you nothing about who spoke. In a one-to-one chat the room's display name already *is*
    /// the other person's name, so a sender line would print it a second time, directly under
    /// itself, and tell nobody anything.
    ///
    /// The last line is the one that had to be *found*, not reasoned out. This rule first
    /// keyed off `isDm` alone, which is wrong, and `Iskra --probe-notification` said so on the
    /// first real message it ever decrypted: the matrix.org welcome room — which every new
    /// account has — is **not** flagged `isDm`, and yet its display name is exactly the name of
    /// the account that writes in it. The notification came out titled "Matrix.org (Official
    /// Account)" with "Matrix.org (Official Account)" written underneath. So the rule is not
    /// "is this a DM"; it is *never say the same name twice*, which is the thing a person
    /// actually sees, and `isDm` is only one way of arriving at it.
    static func attribution(roomName: String,
                            senderName: String,
                            isDirect: Bool,
                            localName: String? = nil) -> (title: String, sender: String?) {
        // The name this device was told to use wins outright, and takes the second line with it.
        // A nickname exists only in a personal chat, where the sender *is* the chat — so printing
        // «Мама» over `anna_1987` would undo the rename on the one screen the user cannot open to
        // fix it. See `LocalNames`.
        if let localName, !localName.isEmpty { return (localName, nil) }

        // A nameless sender falls back to the room, because a blank second line and a
        // duplicated one are the two ways this goes wrong.
        guard !senderName.isEmpty else { return (roomName, nil) }

        let title = isDirect ? senderName : roomName
        return (title, senderName == title ? nil : senderName)
    }

    /// The words for one event. Nil means "not news" — see `PushOutcome.Silence`.
    static func text(for content: MessageLikeEventContent) -> String? {
        switch content {
        case let .roomMessage(messageType, _):
            // The very sentence the chat list would write for this message — see
            // `MessagePreview.text(for:)`. Shared on purpose: a photo should not be "Photo" in
            // one place and "Image" in the other.
            return MessagePreview.text(for: messageType)

        case .poll:
            return String(core: CoreStrings.Preview.poll)

        case .sticker:
            return String(core: CoreStrings.Preview.sticker)

        case .roomEncrypted:
            // Still encrypted after all that: the key for this message never reached this
            // device. Saying so beats silence — something was said, and the user is entitled
            // to know that much even though we cannot say what.
            return String(core: CoreStrings.Preview.unreadable)

        default:
            // Reactions, call negotiation, key-verification steps, redactions. All events;
            // none of them news. The push rules usually strip these long before they reach
            // us, and where they do not, this does.
            return nil
        }
    }
}
