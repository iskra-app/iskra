import SwiftUI
import IskraCore
import IskraDesign

/// The archive: chats the user swept out of the main list, kept whole and one screen away.
///
/// It reads like the main list on purpose — the same `RoomRow`, the same swipes — because an
/// archived chat is not a different kind of thing, it is an ordinary chat put on a shelf. The one
/// difference is the trailing swipe lifts it back out ("Unarchive") instead of putting it away.
///
/// Opening a chat here hands the room back up to the list, which selects it and pops this screen:
/// the archive is a place you came from, not one you read in.
struct ArchiveView: View {
    let session: UserSession
    var onOpen: (String) -> Void

    @State private var roomToLeave: RoomSummary?

    var body: some View {
        List {
            ForEach(session.roomList.archivedRooms) { room in
                Button {
                    onOpen(room.id)
                } label: {
                    RoomRow(room: room)
                }
                .buttonStyle(.plain)
                .roomListSwipeActions(room: room,
                                      roomList: session.roomList,
                                      onLeave: { roomToLeave = room })
            }
        }
        .listStyle(.plain)
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
