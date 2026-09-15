import SwiftUI
import UserNotifications
import IskraCore

/// What happens when somebody taps the banner, and whether the banner is shown at all.
///
/// The extension already writes the answer down: `content.userInfo = ["room_id": roomID]`, with a
/// comment saying it is "what the app opens to when the notification is tapped". It was not. Nothing
/// in the project read that key, nothing was a `UNUserNotificationCenterDelegate`, and a tap did
/// what a tap on any app's icon does — opened whatever screen the app was left on. A notification
/// that says "Аня: приду через час" and then opens a list of chats has made the reader do the
/// finding twice.
///
/// It is held here rather than in the app shell because it is a decision about screens, and the
/// shell owns the bundle and nothing else (`CLAUDE.md`). The delegate over there forwards two
/// callbacks and keeps no state.
///
/// ## Why a held value and not the `ChatDirectory` slot
///
/// Shortcuts asks for a room by writing it into the shared defaults and letting the root view pick
/// it up on the next foreground (`ChatDirectory.requestOpen`). That is right for Shortcuts — the
/// intent runs in *another process*, and the slot is the only thing the two share. A tap is not
/// that: it arrives in this process, on the main actor, at a moment that races the foreground it
/// causes. Going through the defaults would mean writing at whatever instant iOS delivers the tap
/// and reading on a `.active` that may already have happened — a notification that opens the right
/// room only sometimes, and opens it a whole launch late the rest of the time.
///
/// So the room is held right here until somebody takes it. A cold launch is covered by the same
/// property: the tap is delivered before there are any screens, `roomToOpen` simply waits, and the
/// root view reads it when the signed-in tree appears.
@MainActor
@Observable
public final class PushRouter {
    public static let shared = PushRouter()

    /// The conversation a tapped notification asked for, until it is opened.
    public private(set) var roomToOpen: String?

    /// The conversation on screen right now, if any. A banner about the chat the reader is already
    /// looking at is not news — the message itself is about to appear in front of them.
    public var visibleRoomID: String?

    private init() {}

    /// Somebody tapped a banner. Called by the app delegate.
    public func tapped(roomID: String) {
        roomToOpen = roomID
    }

    /// Takes the pending room, if there is one, and forgets it — so that a second foreground does
    /// not reopen a conversation the reader has since navigated away from.
    public func takeRoomToOpen() -> String? {
        defer { roomToOpen = nil }
        return roomToOpen
    }

    /// A push arrived while the app is in front. Returns how to present it.
    ///
    /// Everything except the room already being open: iOS shows nothing at all by default for a
    /// foreground notification, which would mean somebody reading one chat never learns that
    /// another one has said something.
    public func presentation(forRoomID roomID: String?) -> UNNotificationPresentationOptions {
        guard let roomID, roomID == visibleRoomID else { return [.banner, .sound, .list] }
        // The room is on screen. The message is arriving in the timeline behind the banner, so the
        // banner would be the same sentence twice — and the sound, a second alert for one event.
        return []
    }
}
