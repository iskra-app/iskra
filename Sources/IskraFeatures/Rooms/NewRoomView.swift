import SwiftUI
import IskraCore
import IskraDesign

/// Making a room: a name, a topic, and whether anybody may walk in.
///
/// What is *not* asked is whether it should be encrypted: that follows from whether the room is
/// open, and the sentence under the switch says so. See `UserSession.createRoom` for why those
/// two questions are one.
///
/// Pushed from "New chat" rather than a sheet of its own, so the way back is the stack's — and
/// the way *out*, once the room exists, is handed in: `onCreated` closes the whole sheet.
struct NewRoomView: View {
    let session: UserSession

    /// The new room, once it exists — and it does exist by the time this is called, which is
    /// the whole job of `awaitRoomRemoteEcho`. The caller may open it immediately.
    var onCreated: (String) -> Void

    @State private var name = ""
    @State private var topic = ""
    @State private var isPublic = false

    @State private var isCreating = false
    @State private var failure: RoomCreationFailure?

    @FocusState private var isFocused: Bool

    var body: some View {
        Form {
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
                .accentControl()
            } footer: {
                VStack(alignment: .leading, spacing: Theme.Spacing.close) {
                    // What the room will be, said the way the info screen says what a room is —
                    // the same padlock, the same tint, the same small print — and turning over
                    // the moment the switch does.
                    HStack(spacing: Theme.Spacing.tight) {
                        Image(systemName: privacy.iconName)
                            .foregroundStyle(privacy == .protected ? .secondary : Color.orange)
                            .contentTransition(.symbolEffect(.replace))
                        Text(isPublic ? Strings.RoomList.New.willNotBeEncrypted
                                      : Strings.RoomList.New.willBeEncrypted)
                            .contentTransition(.opacity)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityElement(children: .combine)

                    // The one thing the switch does that its own label does not say.
                    Text(Strings.RoomList.New.openMeansUnencrypted)
                }
                .animation(.smooth, value: isPublic)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(Text(Strings.RoomList.newRoom))
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if isCreating {
                    ProgressView()
                } else {
                    Button(String(app: Strings.RoomList.New.create)) {
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

    /// What `UserSession.createRoom` will make of the switch: an open room goes unencrypted.
    private var privacy: PrivacyStatus { isPublic ? .notProtected : .protected }

    private var isReady: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func create() async {
        guard isReady, !isCreating else { return }
        isCreating = true

        do {
            onCreated(try await session.createRoom(named: name, topic: topic, isPublic: isPublic))
        } catch {
            failure = error
            isCreating = false
        }
    }
}
