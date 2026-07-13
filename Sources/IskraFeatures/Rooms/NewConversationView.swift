import SwiftUI
import IskraCore
import IskraDesign

/// Starting something: a conversation with one person, or a room.
///
/// One sheet for both, because they are the same act with different questions — and the
/// difference between them is exactly two fields, which is not a screen's worth of
/// difference. What is *not* asked is whether it should be encrypted: that follows from
/// whether the room is open, and the sentence under the switch says so. See
/// `UserSession.createRoom` for why those two questions are one.
struct NewConversationView: View {
    enum Kind: String, Identifiable {
        /// One other person, by their Matrix ID.
        case directChat
        /// A room, with a name.
        case room

        var id: String { rawValue }
    }

    let kind: Kind
    let session: UserSession

    /// The new room, once it exists — and it does exist by the time this is called, which is
    /// the whole job of `awaitRoomRemoteEcho`. The caller may open it immediately.
    var onCreated: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var topic = ""
    @State private var address = ""
    @State private var isPublic = false

    @State private var isCreating = false
    @State private var failure: RoomCreationFailure?

    @FocusState private var isFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                switch kind {
                case .directChat: person
                case .room: room
                }
            }
            .formStyle(.grouped)
            .navigationTitle(Text(kind == .directChat ? Strings.RoomList.newChat : Strings.RoomList.newRoom))
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(app: Strings.Room.Manage.cancel)) { dismiss() }
                }

                ToolbarItem(placement: .confirmationAction) {
                    if isCreating {
                        ProgressView()
                    } else {
                        Button(String(app: kind == .directChat ? Strings.RoomList.New.start
                                                               : Strings.RoomList.New.create)) {
                            Task { await create() }
                        }
                        .disabled(!isReady)
                    }
                }
            }
            // The room is being made on a server that may be slow about it. Nothing here
            // should be touchable while it is: a second "Create" is a second room.
            .disabled(isCreating)
            .failureAlert($failure)
            .onAppear { isFocused = true }
        }
    }

    /// A conversation with one person: their address, and nothing else. There is no name to
    /// give it — a one-to-one chat is called after whoever is in it.
    private var person: some View {
        Section {
            TextField(String(app: Strings.Room.Manage.invitePlaceholder), text: $address)
                .focused($isFocused)
                .textContentType(.username)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                #endif
                .onSubmit { Task { await create() } }
        } header: {
            Text(Strings.Room.Manage.inviteTitle)
        } footer: {
            Text(Strings.Room.Manage.inviteHelp)
        }
    }

    @ViewBuilder
    private var room: some View {
        Section {
            TextField(String(app: Strings.Room.Manage.namePlaceholder), text: $name)
                .focused($isFocused)
                .onSubmit { if isReady { Task { await create() } } }

            TextField(String(app: Strings.Room.Manage.topicPlaceholder), text: $topic, axis: .vertical)
                .lineLimit(1...4)
        }

        Section {
            Toggle(isOn: $isPublic) {
                VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                    Text(Strings.Room.Manage.openToAnyone)
                    Text(Strings.Room.Manage.openToAnyoneHelp)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } footer: {
            // The one thing the switch does that its own label does not say.
            Text(Strings.RoomList.New.openMeansUnencrypted)
        }
    }

    /// There is enough here to make something. Nothing more is checked in the view: whether
    /// an address is an address is `IskraCore`'s question, and it answers it in one place —
    /// `RoomDetailsStore.isMatrixID` — for the invite field and for this one alike.
    private var isReady: Bool {
        switch kind {
        case .directChat: !address.trimmingCharacters(in: .whitespaces).isEmpty
        case .room: !name.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    private func create() async {
        guard isReady, !isCreating else { return }
        isCreating = true

        do {
            let roomID = switch kind {
            case .directChat:
                try await session.createDirectChat(with: address)
            case .room:
                try await session.createRoom(named: name, topic: topic, isPublic: isPublic)
            }

            onCreated(roomID)
            dismiss()
        } catch {
            failure = error
            isCreating = false
        }
    }
}
