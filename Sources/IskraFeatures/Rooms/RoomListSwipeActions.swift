import SwiftUI
import IskraCore

/// The swipe actions a chat row carries, in both the main list and the archive.
///
/// Two edges, in the iOS idiom (Mail, Messages):
/// - **Leading** (swipe the row to the right): mark read/unread, and pin/unpin.
/// - **Trailing** (swipe it to the left): archive/unarchive, and delete.
///
/// The first action on each edge is the full-swipe default, so a decisive swipe reads as read on
/// one side and archives on the other — never leaves, because leaving cannot be undone and asks
/// first (`onLeave`). Each toggle labels itself by what the *next* press does, so a pinned row's
/// action says "Unpin", not "Pin".
///
/// VoiceOver reaches all of this without the gesture: SwiftUI surfaces `swipeActions` into the
/// element's actions rotor automatically, which is exactly the accessibility path the design calls
/// for — the swipe is the shortcut, not the only door.
private struct RoomListSwipeActions: ViewModifier {
    let room: RoomSummary
    let roomList: RoomListStore
    let onLeave: () -> Void

    func body(content: Content) -> some View {
        content
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                Button {
                    Task {
                        if room.hasUnread {
                            await roomList.markRead(roomID: room.id)
                        } else {
                            await roomList.markUnread(roomID: room.id)
                        }
                    }
                } label: {
                    if room.hasUnread {
                        Label(String(app: Strings.RoomList.Swipe.markRead), systemImage: "envelope.open")
                    } else {
                        Label(String(app: Strings.RoomList.Swipe.markUnread), systemImage: "envelope.badge")
                    }
                }
                .tint(.blue)

                Button {
                    Task { await roomList.setPinned(roomID: room.id, !room.isPinned) }
                } label: {
                    if room.isPinned {
                        Label(String(app: Strings.RoomList.Swipe.unpin), systemImage: "pin.slash")
                    } else {
                        Label(String(app: Strings.RoomList.Swipe.pin), systemImage: "pin")
                    }
                }
                .tint(.orange)
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button {
                    Task { await roomList.setArchived(roomID: room.id, !room.isArchived) }
                } label: {
                    if room.isArchived {
                        Label(String(app: Strings.RoomList.Swipe.unarchive), systemImage: "tray.and.arrow.up")
                    } else {
                        Label(String(app: Strings.RoomList.Swipe.archive), systemImage: "archivebox")
                    }
                }
                .tint(.indigo)

                Button(role: .destructive, action: onLeave) {
                    Label(String(app: Strings.RoomList.Swipe.delete), systemImage: "trash")
                }
                // The root view tints the whole interface `.primary` by default, and on iOS 26
                // that washes out the destructive swipe-action colour. `.tint(.red)` restores it
                // without touching the row's own accent elsewhere.
                .tint(.red)
            }
    }
}

extension View {
    /// Attaches the chat-row swipe actions. `onLeave` arms the caller's confirmation — leaving is the
    /// one action that never fires straight from the swipe.
    func roomListSwipeActions(room: RoomSummary,
                              roomList: RoomListStore,
                              onLeave: @escaping () -> Void) -> some View {
        modifier(RoomListSwipeActions(room: room, roomList: roomList, onLeave: onLeave))
    }
}
