import SwiftUI
import PhotosUI
import IskraCore
import IskraDesign

/// The chat's picture, its name, what it is for and who may walk in — on a screen that exists to
/// change them.
///
/// Reached by the pencil in the corner of `RoomInfoView`, and only ever shown to somebody the
/// room actually lets change something: the pencil is not drawn otherwise. Each field appears on
/// its own terms too, because Matrix grants the three powers separately — a moderator may well be
/// allowed to rename a room and not to replace its picture, and a greyed-out control would be the
/// app promising something the homeserver has already refused.
///
/// A personal chat has none of those three — the name, the description and the picture all belong
/// to the person you are talking to — and it has one field of its own instead: what *you* call
/// them, on this device. That used to sit as a text field on the info screen, permanently open, in
/// the middle of a page that is otherwise read-only. It is here now, behind the same pencil, for
/// the same reason the room's own name is: a screen you read should not also be a screen one
/// careless tap edits. The warning that the nickname never leaves this device stays under the
/// field, where somebody typing it is looking — it is not a disclaimer, it is the feature.
///
/// No Save button, for the same reason as everywhere else in this app: every field here commits
/// when it is left, and leaving the screen counts as leaving the field.
struct RoomEditView: View {
    let details: RoomDetailsStore

    @Environment(\.isOffline) private var isOffline

    @State private var draftName = ""
    @State private var draftTopic = ""

    /// What to call the person at the other end of a personal chat. Kept apart from `draftName`,
    /// which is the room's own name on the server — these are two different names with two
    /// different audiences, and one of them is never sent anywhere.
    @State private var draftLocalName = ""

    @State private var isChoosingPicture = false
    @State private var pickedPicture: PhotosPickerItem?

    @FocusState private var focus: Field?

    private enum Field {
        case name
        case topic
        case localName
    }

    /// A room, as opposed to a conversation with one person. Asked of what the chat *is* rather
    /// than of how many people are in it — see `RoomInfoView.isRoom`, which asks it the same way.
    private var isRoom: Bool { details.kind != .direct }

    var body: some View {
        Form {
            if !isRoom {
                // Their face at the top, as on every person's page — and what the screen's layout
                // assumes (`profileScreen()` lifts the form under the bar to meet a portrait). With
                // nothing there the name field itself went up under the toolbar.
                Section {
                    RoomAvatar(name: details.name, url: details.avatarURL,
                               size: Theme.Size.avatarProfile, seed: details.avatarSeed)
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, Theme.Spacing.roomy)
                        .profileHeaderRow()
                }
                contactName
            }

            if isRoom, details.permissions.canChangePicture {
                Section {
                    picture
                        .profileHeaderRow()
                }
            }

            if isRoom, details.permissions.canRename {
                Section {
                    TextField(String(app: Strings.Room.Manage.namePlaceholder), text: $draftName)
                        .focused($focus, equals: .name)
                        .onSubmit { focus = nil }
                        .disabled(isOffline)
                } header: {
                    Text(Strings.Room.Manage.nameHeader)
                }
            }

            if isRoom, details.permissions.canChangeTopic {
                Section {
                    TextField(String(app: Strings.Room.Manage.topicPlaceholder),
                              text: $draftTopic,
                              axis: .vertical)
                        .lineLimit(1...6)
                        .focused($focus, equals: .topic)
                        .disabled(isOffline)
                } header: {
                    Text(Strings.Room.about)
                }
            }

            // Whether anybody can find the room and walk in. A setting of the room, like its name,
            // so it lives here with the name rather than on the screen people read.
            if isRoom, details.permissions.canChangeVisibility {
                Section {
                    Toggle(isOn: Binding(get: { details.isPublic },
                                         set: { open in Task { await details.setPublic(open) } })) {
                        VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                            Text(Strings.Room.Manage.openToAnyone)
                            Text(Strings.Room.Manage.openToAnyoneHelp)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accentControl()
                    .disabled(isOffline)
                }
            }

            // Who runs the room and what everybody else may do — for whoever may change the room's
            // power levels, which in practice is its administrators. A screen of its own, because
            // it is two lists, not a field.
            if isRoom, details.permissions.canChangeRoles {
                Section {
                    NavigationLink {
                        RoomRulesView(details: details)
                    } label: {
                        Label {
                            Text(Strings.Room.Rules.title)
                        } icon: {
                            Image(systemName: "person.badge.key")
                        }
                    }
                }
            }

            if isRoom, isOffline {
                Section {
                } footer: {
                    Text(Strings.Room.Manage.offline)
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
        // The nickname follows the chat too, except while it is being typed.
        .onChange(of: details.localName, initial: true) { _, local in
            if focus != .localName { draftLocalName = local ?? "" }
        }
        .onChange(of: focus) { previous, _ in
            switch previous {
            case .name: Task { await details.rename(to: draftName) }
            case .topic: Task { await details.setTopic(draftTopic) }
            // No `Task`, and no server: the nickname is written to this device and read back by
            // the room list and the header at once. See `LocalNames`.
            case .localName: details.renameLocally(to: draftLocalName)
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
            if focus == .localName { details.renameLocally(to: draftLocalName) }
        }
        .photosPicker(isPresented: $isChoosingPicture, selection: $pickedPicture, matching: .images)
        .onChange(of: pickedPicture) { _, item in
            guard let item else { return }
            Task { await setPicture(item) }
        }
        .failureAlert(Binding(get: { details.failure }, set: { details.failure = $0 }))
    }

    /// What to call the person at the other end of a personal chat — on this device, and nowhere
    /// else.
    ///
    /// The one field in this app that changes something without telling the server, and the reason
    /// it exists: a Matrix display name belongs to whoever set it, so a friend who calls themselves
    /// `anna_1987` is `anna_1987` in the list, in the header and on the lock screen — and Matrix's
    /// own answer, renaming the room, writes a state event the other person receives and can read.
    /// Nobody wants to announce what they have decided to call somebody.
    ///
    /// So the footer says it plainly: this name stays on this device, it does not travel to the
    /// other person or to the user's other phones, and signing out forgets it.
    ///
    /// Nothing here is disabled offline, alone on this screen, and that is the point of it: there
    /// is no request to fail.
    @ViewBuilder
    private var contactName: some View {
        Section {
            // The placeholder is the name the server gives, so an empty field is not a blank: it
            // says, in grey, exactly whose name is being replaced and what comes back if the field
            // is emptied.
            TextField(details.serverName, text: $draftLocalName)
                .focused($focus, equals: .localName)
                .onSubmit { focus = nil }

            if details.localName != nil {
                Button {
                    draftLocalName = ""
                    details.renameLocally(to: nil)
                } label: {
                    Text(Strings.Room.LocalName.reset(details.serverName))
                }
            }
        } header: {
            Text(Strings.Room.LocalName.header)
        } footer: {
            Text(Strings.Room.LocalName.help)
        }
    }

    /// The picture, dimmed under a pencil — tapping it offers to change it or remove it.
    private var picture: some View {
        EditableAvatar(name: details.name,
                       url: details.avatarURL,
                       shape: details.kind == .space ? .roundedSquare : .circle,
                       seed: details.kind == .space ? nil : details.avatarSeed,
                       canRemove: details.avatarURL != nil,
                       onChange: { isChoosingPicture = true },
                       onRemove: { Task { await details.removePicture() } })
            .disabled(isOffline)
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
