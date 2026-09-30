import UserNotifications
import IskraCore

/// Taking a conversation's notifications off the lock screen and out of Notification Centre once
/// it has been opened.
///
/// The banners are about messages the reader is now looking at. Left behind, they are a stack of
/// "Аня: …" for a chat that has already been read — and on the next glance at the phone they look
/// exactly like new ones.
///
/// Matched on `threadIdentifier`, which the notification extension sets to the room ID, and on the
/// `room_id` it puts in `userInfo` as well — two keys written by the same line of code, checked
/// together so that a notification from an older build of the extension is still recognised.
///
/// Called from the root view and never from `PushRouter`: the router is exercised by tests, and
/// `UNUserNotificationCenter.current()` in a process with no app bundle does not fail, it crashes.
@MainActor
enum DeliveredNotifications {
    static func clear(roomID: String) {
        Task {
            let centre = UNUserNotificationCenter.current()
            let identifiers = await centre.deliveredNotifications()
                .filter { notification in
                    let content = notification.request.content
                    return content.threadIdentifier == roomID
                        || content.userInfo["room_id"] as? String == roomID
                }
                .map(\.request.identifier)
            guard !identifiers.isEmpty else { return }
            centre.removeDeliveredNotifications(withIdentifiers: identifiers)
        }
    }

    /// An account has left the device: its decrypted banners go with it. They are other people's
    /// words, in the clear in Notification Center, for an account that is not here any more.
    /// `nil` — the last account gone — clears every one.
    static func clear(account: String?) {
        let centre = UNUserNotificationCenter.current()
        guard let account else {
            centre.removeAllDeliveredNotifications()
            return
        }
        Task {
            let identifiers = await centre.deliveredNotifications()
                .filter { $0.request.content.userInfo[PushRegistration.accountKey] as? String == account }
                .map(\.request.identifier)
            guard !identifiers.isEmpty else { return }
            centre.removeDeliveredNotifications(withIdentifiers: identifiers)
        }
    }
}
