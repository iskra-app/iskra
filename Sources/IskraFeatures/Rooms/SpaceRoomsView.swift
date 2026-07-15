import SwiftUI
import IskraCore
import IskraDesign

/// The rooms inside a space — «пространство». Reached by tapping a space in the chat list; it does
/// not open a conversation of its own, because a space is not one.
///
/// Its rows read like the chat list's — a face, a name — so a space feels like a folder of the same
/// chats rather than a different kind of place. Tapping a room opens it back in the main column. A
/// space nested inside this one pushes another of these screens, so a tree of spaces is walked the
/// way a tree of folders is.
struct SpaceRoomsView: View {
    let spaceID: String
    let spaceName: String
    let session: UserSession
    var onOpenRoom: (String) -> Void

    @State private var store: SpaceStore?
    @State private var openedChildSpace: SpaceRoomSummary?

    init(space: RoomSummary, session: UserSession, onOpenRoom: @escaping (String) -> Void) {
        self.spaceID = space.id
        self.spaceName = space.name
        self.session = session
        self.onOpenRoom = onOpenRoom
    }

    /// The recursive entry, for a space found inside another.
    init(childSpace: SpaceRoomSummary, session: UserSession, onOpenRoom: @escaping (String) -> Void) {
        self.spaceID = childSpace.id
        self.spaceName = childSpace.name
        self.session = session
        self.onOpenRoom = onOpenRoom
    }

    var body: some View {
        List {
            if let store {
                ForEach(store.rooms) { room in
                    Button {
                        if room.isSpace {
                            openedChildSpace = room
                        } else {
                            onOpenRoom(room.id)
                        }
                    } label: {
                        row(room)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(Text(verbatim: spaceName))
        .toolbarTitleDisplayMode(.inline)
        .overlay { state }
        .navigationDestination(item: $openedChildSpace) { child in
            SpaceRoomsView(childSpace: child, session: session, onOpenRoom: onOpenRoom)
        }
        .task {
            let store = session.space(forRoomID: spaceID)
            self.store = store
            await store.load()
        }
    }

    private func row(_ room: SpaceRoomSummary) -> some View {
        HStack(spacing: Theme.Spacing.normal) {
            Avatar(name: room.name, url: room.avatarURL, size: Theme.Size.roomAvatar,
                   shape: room.isSpace ? .roundedSquare : .circle)
            VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                Text(room.name)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                if let topic = room.topic, !topic.isEmpty {
                    Text(topic)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if room.isSpace {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private var state: some View {
        if let store, !store.isLoading, store.rooms.isEmpty {
            ContentUnavailableView(String(app: Strings.Room.spaceEmptyTitle),
                                   systemImage: "square.grid.2x2",
                                   description: Text(Strings.Room.spaceEmptyMessage))
        } else if store?.isLoading ?? true {
            ProgressView()
        }
    }
}
