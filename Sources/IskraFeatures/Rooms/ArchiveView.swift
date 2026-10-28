import SwiftUI
import IskraCore
import IskraDesign

/// The archive: chats the user swept out of the main list, kept whole and one screen away.
///
/// It reads like the main list on purpose — the same `RoomRow`, the same swipes — because an
/// archived chat is not a different kind of thing, it is an ordinary chat put on a shelf. The one
/// difference is the trailing swipe lifts it back out ("Unarchive") instead of putting it away.
///
/// Opening a chat here hands the room back up to the list, which selects it; on a phone the chat
/// is pushed over this screen, and Back comes back here.
struct ArchiveView: View {
    let session: UserSession
    var onOpen: (String) -> Void

    /// On a phone, the chat opened from here — pushed onto *this* screen's stack, so it slides in
    /// over the archive and Back comes back to it. See `RoomListView` for why the selection that
    /// the main list uses cannot do this on a phone. Nil on iPad and Mac, where the chat goes to
    /// the detail column beside the archive and nothing is pushed here.
    var pushed: Binding<String?>?

    @State private var roomToLeave: RoomSummary?

    @Environment(\.chatPeek) private var chatPeek

    var body: some View {
        List {
            ForEach(session.roomList.archivedRooms) { room in
                Button {
                    // The finger that held this row for a peek, coming back up — see
                    // `ChatPeekPresenter.isPeeking(at:)`.
                    guard chatPeek?.isPeeking(at: room.id) != true else { return }
                    onOpen(room.id)
                } label: {
                    RoomRow(room: room, isTyping: session.roomList.typingRoomIDs.contains(room.id))
                }
                .buttonStyle(.plain)
                // Rules *between* chats, and none above the first or below the last — the
                // same rule the main list keeps.
                .separatorsBetweenRowsOnly(isFirst: room.id == session.roomList.archivedRooms.first?.id,
                                           isLast: room.id == session.roomList.archivedRooms.last?.id)
                .roomListSwipeActions(room: room,
                                      roomList: session.roomList,
                                      onLeave: { roomToLeave = room })
                .chatPeek(room, session: session) { onOpen(room.id) }
            }
        }
        .listStyle(.plain)
        .navigationDestination(item: pushed ?? .constant(nil)) { roomID in
            ArchivedRoom(session: session, roomID: roomID) { pushed?.wrappedValue = nil }
        }
        .navigationTitle(Text(Strings.RoomList.Archive.title))
        .toolbarTitleDisplayMode(.inline)
        .overlay { emptyState }
        .confirmationDialog(Text(Strings.RoomList.Swipe.leaveConfirmTitle),
                            isPresented: Binding(get: { roomToLeave != nil },
                                                 set: { if !$0 { roomToLeave = nil } }),
                            titleVisibility: .visible,
                            presenting: roomToLeave) { room in
            Button(String(app: Strings.RoomList.Swipe.leaveConfirm), role: .destructive) {
                Task { await session.roomList.leave(roomID: room.id) }
                roomToLeave = nil
            }
            Button(String(app: Strings.RoomList.Swipe.cancel), role: .cancel) {
                roomToLeave = nil
            }
        } message: { _ in
            Text(Strings.RoomList.Swipe.leaveConfirmMessage)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if session.roomList.archivedRooms.isEmpty {
            ContentUnavailableView(String(app: Strings.RoomList.Archive.emptyTitle),
                                   systemImage: "archivebox",
                                   description: Text(Strings.RoomList.Archive.emptyMessage))
        }
    }
}

/// A chat opened from the archive on a phone, as the detail column would show it — and doing the
/// two things the root does for the chat it selects: telling notifications this room is on screen,
/// and clearing what was delivered for it.
private struct ArchivedRoom: View {
    let session: UserSession
    let roomID: String
    let close: () -> Void

    @State private var openAt: String?

    var body: some View {
        if let timeline = session.timeline(forRoomID: roomID) {
            RoomView(timeline: timeline,
                     identityChanges: session.identityChanges(forRoomID: roomID),
                     makeDetails: { session.details(forRoomID: roomID) },
                     makeThread: { session.threadTimeline(forRoomID: roomID, rootEventID: $0) },
                     openAt: $openAt,
                     onLeave: close,
                     onClose: close)
                .id(roomID)
                .onAppear {
                    PushRouter.shared.visibleRoomID = roomID
                    PushRouter.shared.visibleAccountID = session.sessionID
                    DeliveredNotifications.clear(roomID: roomID)
                }
                .onDisappear {
                    if PushRouter.shared.visibleRoomID == roomID { PushRouter.shared.visibleRoomID = nil }
                }
        }
    }
}
