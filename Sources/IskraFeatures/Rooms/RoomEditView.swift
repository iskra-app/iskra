import SwiftUI
import PhotosUI
import IskraCore
import IskraDesign

/// The chat's picture, its name and what it is for — on a screen that exists to change them.
///
/// Reached by the pencil in the corner of `RoomInfoView`, and only ever shown to somebody the
/// room actually lets change something: the pencil is not drawn otherwise. Each field appears on
/// its own terms too, because Matrix grants the three powers separately — a moderator may well be
/// allowed to rename a room and not to replace its picture, and a greyed-out control would be the
/// app promising something the homeserver has already refused.
///
/// No Save button, for the same reason as everywhere else in this app: the name and the topic
/// commit when the field is left, and leaving the screen counts as leaving the field.
struct RoomEditView: View {
    let details: RoomDetailsStore

    @Environment(\.isOffline) private var isOffline

    @State private var draftName = ""
    @State private var draftTopic = ""

    @State private var isChoosingPicture = false
    @State private var pickedPicture: PhotosPickerItem?

    @FocusState private var focus: Field?

    private enum Field {
        case name
        case topic
    }

    var body: some View {
        Form {
            if details.permissions.canChangePicture {
                Section {
                    picture
                        .profileHeaderRow()
                }
            }

            if details.permissions.canRename {
                Section {
                    TextField(String(app: Strings.Room.Manage.namePlaceholder), text: $draftName)
                        .focused($focus, equals: .name)
                        .onSubmit { focus = nil }
                        .disabled(isOffline)
                } header: {
                    Text(Strings.Room.Manage.nameHeader)
                }
            }

            if details.permissions.canChangeTopic {
                Section {
                    TextField(String(app: Strings.Room.Manage.topicPlaceholder),
                              text: $draftTopic,
                              axis: .vertical)
                        .lineLimit(1...6)
                        .focused($focus, equals: .topic)
                        .disabled(isOffline)
                } header: {
                    Text(Strings.Room.about)
                } footer: {
                    if isOffline {
                        Text(Strings.Room.Manage.offline)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .profileScreen()
        // The fields follow the room, except while somebody is typing in them — a name that
        // arrives from a sync must not overwrite the one being written.
        .onChange(of: details.name, initial: true) { _, name in
            if focus != .name { draftName = name }
        }
        .onChange(of: details.topic, initial: true) { _, topic in
            if focus != .topic { draftTopic = topic ?? "" }
        }
        .onChange(of: focus) { previous, _ in
            switch previous {
            case .name: Task { await details.rename(to: draftName) }
            case .topic: Task { await details.setTopic(draftTopic) }
            case nil: break
            }
        }
        // And leaving the screen is leaving the field. Focus loss is what commits an edit, and
        // SwiftUI makes no promise that focus resigns before a view is torn down — so tapping
        // back with the keyboard up would drop the rename. Neither call can double-send: both
        // return early when the text has not actually changed.
        //
        // The store is deliberately *not* stopped here. It belongs to `RoomInfoView`, which is
        // still on the stack underneath this screen and still listening to the room.
        .onDisappear {
            if focus == .name { Task { await details.rename(to: draftName) } }
            if focus == .topic { Task { await details.setTopic(draftTopic) } }
        }
        .photosPicker(isPresented: $isChoosingPicture, selection: $pickedPicture, matching: .images)
        .onChange(of: pickedPicture) { _, item in
            guard let item else { return }
            Task { await setPicture(item) }
        }
        .failureAlert(Binding(get: { details.failure }, set: { details.failure = $0 }))
    }

    /// The picture, and the two things that can be done to it spelled out underneath rather
    /// than hidden in a menu on the image.
    private var picture: some View {
        VStack(spacing: Theme.Spacing.normal) {
            Avatar(name: details.name, url: details.avatarURL, size: Theme.Size.avatarProfile)

            VStack(spacing: Theme.Spacing.close) {
                Button {
                    isChoosingPicture = true
                } label: {
                    Text(Strings.Room.Manage.changePicture)
                }
                .disabled(isOffline)

                if details.avatarURL != nil {
                    Button(role: .destructive) {
                        Task { await details.removePicture() }
                    } label: {
                        Text(Strings.Room.Manage.removePicture)
                    }
                    .disabled(isOffline)
                }
            }
            .font(.callout)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Spacing.roomy)
    }

    private func setPicture(_ item: PhotosPickerItem) async {
        pickedPicture = nil

        guard let data = await imageData(from: item) else {
            details.failure = .picture
            return
        }
        await details.setPicture(data, filename: "avatar.jpg")
    }
}
