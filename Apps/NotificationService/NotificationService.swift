import UserNotifications
import Synchronization
import IskraCore

/// The process that turns a push into a sentence.
///
/// iOS wakes this up when a push arrives with `mutable-content`, hands it the payload the
/// homeserver sent — which is a room ID, an event ID and nothing else worth reading — and
/// gives it about thirty seconds to replace the text before it gives up and shows whatever
/// the server wrote. In an encrypted room the server wrote "New message", because the
/// server cannot read the message either. Everything the user sees on their lock screen is
/// decided here.
///
/// As thin as the app shells, and for the same reason: the work is `PushDecoder`, in
/// `IskraCore`, where the `Client` and the crypto store belong. This file knows about
/// `UNNotificationContent`, and that is all it knows.
///
/// `@unchecked Sendable` is not a shrug. Every piece of mutable state here is behind the
/// `Mutex` below, which is the whole reason the class has one; what the compiler cannot see
/// is that `UNNotificationServiceExtension` — an Objective-C class it did not write — is
/// safe to hold across the hop once that is true.
final class NotificationService: UNNotificationServiceExtension, @unchecked Sendable {
    /// The one obligation this process has to iOS: call the content handler, exactly once.
    ///
    /// Two things race for it — the decrypt finishing, and iOS running out of patience — and
    /// they arrive on different threads. So it is *taken* out from under a lock rather than
    /// read: whoever gets here first delivers, and the loser finds nothing and does nothing.
    /// Calling it twice traps; never calling it means the user gets no notification at all.
    /// Both failures are invisible in a simulator and obvious on a phone at 3 a.m.
    /// `@unchecked Sendable` for the same reason `UnsafeTransfer` exists in `RoomListStore`:
    /// the two things in here are an Objective-C block and an Objective-C content object,
    /// neither of which carries a `Sendable` promise, and both of which have to cross from
    /// `didReceive` to the task that decrypts. The box says that out loud instead of quietly
    /// weakening something bigger. What makes it true is the `Mutex` — the handler is reached
    /// through the lock, exactly once, and never held anywhere else.
    private struct Delivery: @unchecked Sendable {
        let handler: (UNNotificationContent) -> Void
        /// iOS's own words for this push — "New message", or whatever the homeserver put in
        /// the payload. Kept, because it is what goes on screen if we run out of time, and
        /// showing it is better than showing nothing.
        let fallback: UNNotificationContent
    }

    private let pending = Mutex<Delivery?>(nil)

    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        // If iOS reuses this instance for a second push before the first has been delivered, the
        // first handler must still be called — exactly once, which is this class's whole reason to
        // exist. Overwriting the box would strand it: a notification that never appears, and a
        // promise to the system that is never kept.
        //
        // So whatever was in there gets its fallback and is let go of, before the new one takes its
        // place. Showing the server's own "New message" for the older push is the right answer:
        // something did arrive, and we are out of time to say what.
        let displaced = pending.withLock { pending -> Delivery? in
            let previous = pending
            pending = Delivery(handler: contentHandler, fallback: request.content)
            return previous
        }

        if let displaced {
            displaced.handler(displaced.fallback)
        }

        // Matrix's push payload. `room_id` and `event_id` are all a gateway forwards, and all
        // it *should* forward: anything more would be the homeserver telling APNs — and
        // therefore Apple — what is inside an end-to-end encrypted room.
        let payload = request.content.userInfo
        guard let roomID = payload["room_id"] as? String,
              let eventID = payload["event_id"] as? String else {
            // Not a message push, or a payload shape we do not know. Leave it exactly as it
            // came rather than blanking it: the server says something arrived, and it is not
            // our place to decide it did not.
            deliverFallback()
            return
        }

        Task {
            let outcome = await PushDecoder().notification(roomID: roomID, eventID: eventID)
            deliver(outcome, roomID: roomID)
        }
    }

    /// The thirty seconds ran out. Whatever we were doing, it is over — iOS will show
    /// *something* now whether we speak or not, so we speak, with the best text we have.
    ///
    /// `PushDecoder` bounds itself at twenty seconds precisely so this is a backstop and not
    /// the normal path: by the time iOS loses patience we should already have given up
    /// ourselves and put an honest fallback on screen.
    override func serviceExtensionTimeWillExpire() {
        Log.push.error("iOS ran out of patience before the event decrypted")
        deliverFallback()
    }

    // MARK: - Private

    private func deliver(_ outcome: PushOutcome, roomID: String) {
        guard let delivery = pending.withLock({ $0.take() }) else { return }

        switch outcome {
        case let .show(notification):
            delivery.handler(content(for: notification,
                                     roomID: roomID,
                                     // Read off the server's own notification, which is the only
                                     // place this number exists — and read here, because the line
                                     // above has already taken `pending` and there is nothing left
                                     // to ask afterwards.
                                     unread: delivery.fallback.userInfo["unread_count"] as? Int))

        case .silence:
            // Nothing to say. There is no supported way for an extension to *drop* a push
            // outright — once iOS has woken us it will show something — so the least it can
            // show is an empty notification, rather than the server's "New message" for a
            // reaction nobody asked to be told about.
            delivery.handler(UNMutableNotificationContent())

        case .notSignedIn, .failed:
            // We could not read it. Leave the server's own text alone: a message described
            // badly still tells the user a message arrived, and silence does not. Why it
            // failed is in `Log.push`, for whoever comes looking.
            delivery.handler(Self.fallback(of: delivery))
        }
    }

    private func deliverFallback() {
        guard let delivery = pending.withLock({ $0.take() }) else { return }
        delivery.handler(Self.fallback(of: delivery))
    }

    /// The server's own words — unless the app is ringing about this very event.
    ///
    /// A ringing call arrives twice: as a VoIP push, which rings, and as an ordinary push, which
    /// wakes this process. The ordinary copy is meant to come to nothing, and does whenever it
    /// decrypts — `PushMapper` returns a silence for it. But this extension has one obligation it
    /// cannot skip, and when it cannot decrypt in time what it hands over is "Новое сообщение".
    /// Landing on top of a call that is ringing at that moment, it reads as two unrelated bugs and
    /// is one.
    ///
    /// So the app writes the ring down where this process can see it. See `RingLedger`, and note
    /// that the check is deliberately narrow: only an event the app has *said* it is ringing about
    /// is silenced, so a genuine message can never be swallowed by this.
    private static func fallback(of delivery: Delivery) -> UNNotificationContent {
        if let eventID = delivery.fallback.userInfo["event_id"] as? String,
           RingLedger.isRinging(eventID: eventID) {
            return UNMutableNotificationContent()
        }
        return delivery.fallback
    }

    private func content(for notification: PushNotification,
                         roomID: String,
                         unread: Int?) -> UNNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        if let sender = notification.sender {
            content.subtitle = sender
        }
        content.body = notification.body
        content.sound = notification.isNoisy ? .default : nil

        // The number on the icon, while the app is closed and cannot count for itself. The count
        // is the homeserver's, carried in the push beside the room and event ids — not something
        // this process works out, which it could not: it holds one event and has no idea what else
        // is waiting. `nil` means the server offered no number, and then the badge is left exactly
        // as it was rather than cleared. The app recomputes it from the room list when it opens.
        if let unread { content.badge = NSNumber(value: unread) }

        // Collapses every push from one conversation into one entry, so a room that gets
        // twenty messages is one line on the lock screen and not twenty.
        content.threadIdentifier = roomID

        // What the app opens to when the notification is tapped. The room, and nothing else —
        // the app already has the conversation. Read by `PushDelegate`, which hands it to
        // `PushRouter`.
        content.userInfo = ["room_id": roomID]

        // And last, the thing that makes it look like a message rather than an app notice: the
        // sender's face, their name in place of ours, its own line in Notification Summary. This
        // returns the content above unchanged until the Communication Notifications capability is
        // enabled on the App IDs — see `CommunicationNotification`, which says what that means.
        //
        // `PushFace` is what fills the circle when the sender has no picture of their own: the app
        // draws a creature for such people, and the lock screen has to draw the same one, in this
        // process, from the same seed.
        return CommunicationNotification.apply(to: content, for: PushFace.applied(to: notification))
    }
}

private extension Optional {
    /// Reads the value and clears it in one move, so that "exactly once" is a property of the
    /// lock rather than of everyone who remembers to nil it out afterwards.
    mutating func take() -> Wrapped? {
        defer { self = nil }
        return self
    }
}
