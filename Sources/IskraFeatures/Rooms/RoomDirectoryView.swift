import SwiftUI
import IskraCore
import IskraDesign

/// The homeserver's public room directory: what is there, a field to narrow it, and a tap to walk
/// in. A room already joined opens rather than being joined twice.
struct PublicRoomsView: View {
    let session: UserSession
    var onOpen: (String) -> Void

    @State private var directory: PublicRoomDirectory?
    @State private var query = ""
    @State private var joining: String?
    @State private var failure: RoomJoinFailure?

    var body: some View {
        List {
            if let directory {
                ForEach(directory.rooms) { room in
                    Button { Task { await open(room) } } label: {
                        PublicRoomRow(room: room, isBusy: joining == room.id)
                    }
                    .buttonStyle(.plain)
                    .disabled(!room.isOpen && !isJoined(room))
                    .onAppear {
                        if room.id == directory.rooms.last?.id {
                            Task { await directory.loadMore() }
                        }
                    }
                }

                footer(directory)
            }
        }
        #if os(iOS)
        .listStyle(.plain)
        .textInputAutocapitalization(.never)
        #endif
        .searchable(text: $query, prompt: Text(Strings.RoomList.New.roomsPrompt))
        .autocorrectionDisabled()
        .task(id: query.trimmingCharacters(in: .whitespaces)) { await search() }
        .disabled(joining != nil)
        .failureAlert($failure)
        .navigationTitle(Text(Strings.RoomList.New.publicRooms))
        .toolbarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func footer(_ directory: PublicRoomDirectory) -> some View {
        if directory.isLoading {
            HStack {
                Spacer()
                ProgressView()
                Spacer()
            }
            .listRowSeparator(.hidden)
        } else if directory.failed {
            HStack {
                Text(Strings.RoomList.New.directoryFailed)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(String(app: Strings.RoomList.New.retry)) {
                    Task { await directory.search(query) }
                }
            }
        } else if directory.rooms.isEmpty {
            Text(Strings.RoomList.New.noRooms)
                .foregroundStyle(.secondary)
        }
    }

    /// The whole directory first, then whatever was typed — a moment after the typing stops.
    private func search() async {
        let directory = self.directory ?? session.publicRooms()
        self.directory = directory

        if !query.trimmingCharacters(in: .whitespaces).isEmpty {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
        }
        await directory.search(query)
    }

    private func isJoined(_ room: PublicRoom) -> Bool {
        session.roomList.rooms.contains { $0.id == room.id && !$0.isInvitation }
    }

    private func open(_ room: PublicRoom) async {
        if isJoined(room) {
            onOpen(room.id)
            return
        }

        guard joining == nil else { return }
        joining = room.id
        do {
            onOpen(try await session.joinRoom(room))
        } catch {
            failure = error
        }
        joining = nil
    }
}

private struct PublicRoomRow: View {
    let room: PublicRoom
    var isBusy = false

    var body: some View {
        HStack(spacing: Theme.Spacing.normal) {
            RoomAvatar(name: room.title, url: room.avatarURL, size: Theme.Size.avatar, seed: room.id)

            VStack(alignment: .leading, spacing: 0) {
                Text(room.title)
                    .lineLimit(1)

                Text(details)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if let topic = room.topic, !topic.isEmpty {
                    Text(topic)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 0)

            if isBusy { ProgressView() }
        }
        .contentShape(Rectangle())
    }

    /// The address and the head count — and, for a room that cannot be walked into, why the tap
    /// does nothing.
    private var details: String {
        var parts: [String] = []
        if let alias = room.alias { parts.append(alias) }
        parts.append(String(app: Strings.Room.participants(room.memberCount)))
        if !room.isOpen { parts.append(String(app: Strings.RoomList.New.inviteOnly)) }
        return parts.joined(separator: " · ")
    }
}

/// Joining a room by what somebody gave you: `#name:server`, or the room's ID.
struct JoinByAddressView: View {
    let session: UserSession
    var onJoined: (String) -> Void

    @State private var address = ""
    @State private var isJoining = false
    @State private var failure: RoomJoinFailure?

    @FocusState private var isFocused: Bool

    var body: some View {
        Form {
            Section {
                TextField(String(app: Strings.RoomList.New.addressPlaceholder), text: $address)
                    .focused($isFocused)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
                    .autocorrectionDisabled()
                    .onSubmit { Task { await join() } }
            } footer: {
                Text(Strings.RoomList.New.addressHelp)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(Text(Strings.RoomList.New.joinByAddress))
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if isJoining {
                    ProgressView()
                } else {
                    Button(String(app: Strings.RoomList.New.join)) {
                        Task { await join() }
                    }
                    .disabled(isEmpty)
                }
            }
        }
        .disabled(isJoining)
        .failureAlert($failure)
        .onAppear { isFocused = true }
    }

    private var isEmpty: Bool {
        address.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func join() async {
        guard !isEmpty, !isJoining else { return }
        isJoining = true
        do {
            onJoined(try await session.joinRoom(address: address))
        } catch {
            failure = error
            isJoining = false
        }
    }
}
