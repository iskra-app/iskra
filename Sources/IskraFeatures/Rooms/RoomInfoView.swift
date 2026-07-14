import SwiftUI
import PhotosUI
import IskraCore
import IskraDesign

/// What this chat is, who is in it, and — for whoever runs it — where that gets changed.
/// Reached by pressing the header above the conversation.
///
/// A real destination pushed onto the navigation stack, like `SettingsView` and for the
/// same reason: the push, the back button and the swipe back are then the system's, and
/// all three are noticeably wrong when you build them yourself.
///
/// This is also where the lock finally speaks. The header shows a closed padlock and says
/// nothing; anyone who wonders what it means presses the name, and the answer is here in
/// a sentence with no cryptography in it.
///
/// There is no "Edit" button, and that is deliberate. The name and the description are
/// fields for anybody allowed to change them and plain text for everybody else, so the
/// screen already shows each reader exactly what they can do — an edit *mode* on top of
/// that would be a second state to enter for the sake of changing one line of text.
struct RoomInfoView: View {
    @State private var details: RoomDetailsStore

    /// Leaving takes the whole conversation off the screen, and only whoever owns the
    /// selection can do that — the same shape as sign-out in `RoomListView`.
    var onLeave: () -> Void

    @Environment(\.dismiss) private var dismiss

    /// Offline, this screen is a *description* of the room rather than a way to change it. Every
    /// control on it — the name, the topic, the picture, who is in it, whether it is open, and the
    /// way out of it — is a call straight to the server with no queue behind it, so all of them are
    /// turned off rather than left to fail one at a time.
    ///
    /// The name and topic fields matter most here, and not for the obvious reason. They commit when
    /// they *lose focus* — so offline somebody could type a new name, watch it sit there looking
    /// applied, walk away, and have it quietly thrown out by a server that was never asked. Disabled,
    /// the field never takes the text in the first place.
    @Environment(\.isOffline) private var isOffline

    /// What is in the two fields, which is not the same thing as what the room is called.
    /// The room is renamed when the field is *left*, not on every keystroke.
    @State private var draftName = ""
    @State private var draftTopic = ""

    @State private var isChoosingPicture = false
    @State private var pickedPicture: PhotosPickerItem?

    @State private var isInviting = false
    @State private var invitee = ""

    /// The person a block has been asked for and not yet confirmed. Blocking is the one
    /// act on this screen with no way back through it.
    @State private var blocking: RoomMemberSummary?
    @State private var isConfirmingLeave = false

    @FocusState private var focus: Field?

    private enum Field {
        case name
        case topic
    }

    init(details: RoomDetailsStore, onLeave: @escaping () -> Void) {
        _details = State(initialValue: details)
        self.onLeave = onLeave
    }

    /// A one-to-one chat has no name, no description and no picture of its own — all three
    /// belong to the person you are talking to. Offering to rename them would be offering
    /// something Matrix will happily do and nobody wants.
    private var isRoom: Bool { !details.isDirectChat }

    var body: some View {
        Form {
            Section {
                identity
            }
            .disabled(isOffline)

            about
                .disabled(isOffline)

            Section {
                privacy

                if isRoom, details.permissions.canChangeVisibility {
                    Toggle(isOn: Binding(get: { details.isPublic },
                                         set: { open in Task { await details.setPublic(open) } })) {
                        VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                            Text(Strings.Room.Manage.openToAnyone)
                            Text(Strings.Room.Manage.openToAnyoneHelp)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .disabled(isOffline)
                }
            }

            Section {
                Picker(selection: Binding(get: { details.alerts },
                                          set: { choice in Task { await details.setAlerts(choice) } })) {
                    ForEach(RoomAlerts.allCases) { choice in
                        Text(Strings.Room.Manage.alerts(choice)).tag(choice)
                    }
                } label: {
                    Label(String(app: Strings.Room.Manage.alerts), systemImage: alertsIcon)
                }
                .disabled(isOffline)
            } footer: {
                // Said once, at the top of everything this screen can no longer do, rather than as a
                // grey control the reader is left to interpret. A disabled switch explains nothing on
                // its own; a person who has not noticed the strip at the top of the screen would
                // simply think the app had broken.
                if isOffline {
                    Text(Strings.Room.Manage.offline)
                }
            }

            members

            Section {
                Button(role: .destructive) {
                    isConfirmingLeave = true
                } label: {
                    Text(Strings.Room.Manage.leave)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                // Leaving is `room.leave()`, straight to the server. Offline it would fail, and it is
                // the one action here where failing quietly would be alarming: a person who pressed
                // "Leave", saw nothing happen, and came back to find themselves still in the room has
                // no way to know whether they left or not.
                .disabled(isOffline)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(Text(Strings.Room.detailsTitle))
        .toolbarTitleDisplayMode(.inline)
        .task { await details.load() }
        // The fields follow the room, except while somebody is typing in them — a name that
        // arrives from a sync must not overwrite the one being written.
        .onChange(of: details.name, initial: true) { _, name in
            if focus != .name { draftName = name }
        }
        .onChange(of: details.topic, initial: true) { _, topic in
            if focus != .topic { draftTopic = topic ?? "" }
        }
        // Leaving a field is what commits it. There is no "Save": a form with one button at
        // the bottom would make renaming a room a two-step act, and the change is a single
        // line of text.
        .onChange(of: focus) { previous, _ in
            switch previous {
            case .name: Task { await details.rename(to: draftName) }
            case .topic: Task { await details.setTopic(draftTopic) }
            case nil: break
            }
        }
        // And leaving the *screen* is leaving the field.
        //
        // Focus loss is what commits an edit, and SwiftUI makes no promise that focus resigns
        // before a view is torn down. So typing a new room name and tapping the back chevron with
        // the keyboard still up dropped the rename on the floor: the field showed the new name
        // right up until the moment you left, and the room was still called the old thing.
        //
        // Committing here as well as above cannot double-send: both `rename` and `setTopic` return
        // early when the text has not actually changed.
        .onDisappear {
            if focus == .name { Task { await details.rename(to: draftName) } }
            if focus == .topic { Task { await details.setTopic(draftTopic) } }

            // And the subscription this screen took out on the room goes with it. It follows the
            // room as it is renamed from other devices — see `RoomDetailsStore.load()` — and a
            // listener nobody cancels is a listener that runs until the account is signed out.
            details.stop()
        }
        // Presented from the root of the screen rather than from inside the menu that asks
        // for it: a `PhotosPicker` declared inside a `Menu` never appears — see
        // `MessageComposer`, where that cost an afternoon.
        .photosPicker(isPresented: $isChoosingPicture, selection: $pickedPicture, matching: .images)
        .onChange(of: pickedPicture) { _, item in
            guard let item else { return }
            Task { await setPicture(item) }
        }
        .alert(Text(Strings.Room.Manage.inviteTitle), isPresented: $isInviting) {
            TextField(String(app: Strings.Room.Manage.invitePlaceholder), text: $invitee)
                .textContentType(.username)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                #endif

            Button(String(app: Strings.Room.Manage.cancel), role: .cancel) { invitee = "" }
            Button(String(app: Strings.Room.Manage.invite)) {
                let userID = invitee
                invitee = ""
                Task { await details.invite(userID) }
            }
        } message: {
            Text(Strings.Room.Manage.inviteHelp)
        }
        .confirmationDialog(Text(blocking.map { Strings.Room.Manage.blockQuestion($0.name) }
                                 ?? Strings.Room.Manage.block),
                            isPresented: Binding(get: { blocking != nil },
                                                 set: { if !$0 { blocking = nil } }),
                            titleVisibility: .visible) {
            Button(String(app: Strings.Room.Manage.block), role: .destructive) {
                guard let member = blocking else { return }
                blocking = nil
                Task { await details.ban(member) }
            }
            Button(String(app: Strings.Room.Manage.cancel), role: .cancel) { blocking = nil }
        } message: {
            Text(Strings.Room.Manage.blockHelp)
        }
        .confirmationDialog(Text(Strings.Room.Manage.leaveQuestion),
                            isPresented: $isConfirmingLeave,
                            titleVisibility: .visible) {
            Button(String(app: Strings.Room.Manage.leave), role: .destructive) {
                Task { await details.leave() }
            }
            Button(String(app: Strings.Room.Manage.cancel), role: .cancel) {}
        } message: {
            Text(Strings.Room.Manage.leaveHelp)
        }
        .failureAlert($details.failure)
        // The room is gone: the screen behind this one is about to be a conversation nobody
        // is in. Both halves are needed — this screen pops itself, and the selection is
        // cleared above, or an iPhone would be left staring at the empty detail column.
        .onChange(of: details.hasLeft) { _, hasLeft in
            guard hasLeft else { return }
            dismiss()
            onLeave()
        }
    }

    /// The room, at the top: its picture, its name, and the one line that says what it is.
    // MARK: - Who or what this room is

    private var identity: some View {
        VStack(spacing: Theme.Spacing.close) {
            picture

            if isRoom, details.permissions.canRename {
                TextField(String(app: Strings.Room.Manage.namePlaceholder), text: $draftName)
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .textFieldStyle(.plain)
                    .focused($focus, equals: .name)
                    .onSubmit { focus = nil }
            } else {
                Text(details.name)
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
            }

            if let subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    // In a one-to-one chat this is the other person's Matrix ID, which is
                    // exactly the string someone opens this screen to copy.
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Spacing.close)
    }

    /// The picture — and, for whoever may change it, a menu on the picture itself. There is
    /// no pencil in the corner: the thing you press is the thing that changes.
    @ViewBuilder
    private var picture: some View {
        let avatar = Avatar(name: details.name, url: details.avatarURL, size: Theme.Size.avatarLarge)

        if isRoom, details.permissions.canChangePicture {
            Menu {
                Button {
                    isChoosingPicture = true
                } label: {
                    Label(String(app: Strings.Room.Manage.changePicture), systemImage: "photo")
                }

                if details.avatarURL != nil {
                    Button(role: .destructive) {
                        Task { await details.removePicture() }
                    } label: {
                        Label(String(app: Strings.Room.Manage.removePicture), systemImage: "trash")
                    }
                }
            } label: {
                avatar
            }
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .accessibilityLabel(Text(Strings.Room.Manage.changePicture))
        } else {
            avatar
        }
    }

    /// The topic: what the room is for, written by whoever runs it. A field for them, and a
    /// paragraph for everybody else — and nothing at all when it is empty and cannot be
    /// filled in, because an empty section is a heading over a blank.
    // MARK: - What it is for, and what it does to your phone

    @ViewBuilder
    private var about: some View {
        let topic = details.topic ?? ""

        if isRoom, details.permissions.canChangeTopic {
            Section {
                TextField(String(app: Strings.Room.Manage.topicPlaceholder),
                          text: $draftTopic,
                          axis: .vertical)
                    .lineLimit(1...6)
                    .focused($focus, equals: .topic)
            } header: {
                Text(Strings.Room.about)
            }
        } else if !topic.isEmpty {
            Section {
                Text(topic)
                    .font(.callout)
                    // People write paragraphs in a room topic, and they are worth reading.
                    // Selectable, because a topic is where the invite link and the rules
                    // tend to live.
                    .textSelection(.enabled)
            } header: {
                Text(Strings.Room.about)
            }
        }
    }

    /// A Matrix ID in a one-to-one chat, a count of people in a room.
    ///
    /// It is not a "last seen" time, and it cannot be: the Rust SDK exposes no presence
    /// over FFI at all. An "online 5 minutes ago" invented from the last message in the
    /// conversation would be a confident lie about where somebody is — see
    /// `TimelineStore.directCounterpartID`.
    private var subtitle: String? {
        if details.isDirectChat {
            return details.counterpartID
        }
        guard details.memberCount > 0 else { return nil }
        return String(app: Strings.Room.participants(details.memberCount))
    }

    /// The bell says what it is doing without being read: a struck-through one for a muted
    /// room is the state people most want to check at a glance, and most want to be sure of.
    private var alertsIcon: String {
        switch details.alerts {
        case .all: "bell"
        case .mentions: "bell.badge"
        case .muted: "bell.slash"
        }
    }

    /// What the padlock in the header means, spelled out. The sentence comes from
    /// `IskraCore`, which is where the app's vocabulary for privacy lives.
    private var privacy: some View {
        Label {
            Text(details.privacy.explanation)
                .font(.callout)
                .foregroundStyle(.secondary)
        } icon: {
            Image(systemName: details.privacy.iconName)
                .foregroundStyle(details.privacy == .protected ? Color.secondary : Color.orange)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Who is in it

    @ViewBuilder
    private var members: some View {
        Section {
            if isRoom, details.permissions.canInvite {
                Button {
                    isInviting = true
                } label: {
                    Label(String(app: Strings.Room.Manage.invite), systemImage: "person.badge.plus")
                }
                .disabled(isOffline)
            }

            if details.isLoadingMembers && details.members.isEmpty {
                // Not an empty list: a room always has at least us in it, so "no one is
                // here" is never the truth — it only ever means we have not looked yet.
                ProgressView()
                    .frame(maxWidth: .infinity)
            } else {
                ForEach(details.members) { member in
                    MemberRow(member: member,
                              roles: details.assignableRoles(for: member),
                              canRemove: details.permissions.canRemove && details.canManage(member),
                              canBlock: details.permissions.canBan && details.canManage(member),
                              setRole: { role in Task { await details.setRole(role, for: member) } },
                              remove: { Task { await details.remove(member) } },
                              block: { blocking = member })
                }
            }
        } header: {
            Text(Strings.Room.participants(details.memberCount))
        }
    }

    // MARK: - Changing it

    private func setPicture(_ item: PhotosPickerItem) async {
        pickedPicture = nil

        guard let data = await imageData(from: item) else {
            details.failure = .picture
            return
        }
        await details.setPicture(data, filename: "avatar.jpg")
    }
}

/// One person in the room: their face, their name, and what they can do here — plus, on a
/// long press, what *you* can do about them.
///
/// The menu is built from what the room allows rather than from what the protocol allows,
/// so a member with no power over anybody has no menu at all. Nothing here is ever shown
/// disabled: a greyed-out "Remove" is a promise the homeserver has already refused.
private struct MemberRow: View {
    let member: RoomMemberSummary
    let roles: [RoomRole]
    let canRemove: Bool
    let canBlock: Bool
    let setRole: (RoomRole) -> Void
    let remove: () -> Void
    let block: () -> Void

    @Environment(\.isOffline) private var isOffline

    /// Nothing in this menu — a role, a removal, a block — is anything but a request to the server,
    /// so offline the row is a row and not a control. The menu is withheld rather than shown greyed:
    /// a context menu the reader has to open in order to find out that it is empty is worse than one
    /// that does not appear.
    private var hasMenu: Bool {
        !isOffline && (!roles.isEmpty || canRemove || canBlock)
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.normal) {
            Avatar(name: member.name, url: member.avatarURL, size: Theme.Size.avatar)

            VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                Text(member.name)
                    .font(.body)
                    .lineLimit(1)

                // Shown only when it settles something. Matrix display names are neither
                // unique nor verified, so two people in a room can both call themselves
                // "Boris" — the SDK notices, and the ID underneath is the part that
                // cannot be copied.
                if member.isNameAmbiguous, member.name != member.id {
                    Text(member.id)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            if let role = roleName {
                Text(role)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, Theme.Spacing.tight)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .contextMenu {
            if hasMenu { menu }
        }
    }

    @ViewBuilder
    private var menu: some View {
        if !roles.isEmpty {
            Picker(String(app: Strings.Room.Manage.role),
                   selection: Binding(get: { member.role }, set: setRole)) {
                ForEach(roles, id: \.self) { role in
                    Text(name(of: role)).tag(role)
                }
            }
            .pickerStyle(.inline)
        }

        if canRemove {
            Button(role: .destructive, action: remove) {
                Label(String(app: Strings.Room.Manage.remove), systemImage: "person.badge.minus")
            }
        }

        if canBlock {
            Button(role: .destructive, action: block) {
                Label(String(app: Strings.Room.Manage.block), systemImage: "hand.raised")
            }
        }
    }

    /// Only the people who run the room are labelled. Everyone else is just here, and a
    /// badge on every single row would say nothing at all.
    private var roleName: LocalizedStringResource? {
        switch member.role {
        case .administrator: Strings.Room.administrator
        case .moderator: Strings.Room.moderator
        case .member: nil
        }
    }

    /// The same three rungs, but in a menu that has to name all of them — including the one
    /// the list leaves blank.
    private func name(of role: RoomRole) -> LocalizedStringResource {
        switch role {
        case .administrator: Strings.Room.administrator
        case .moderator: Strings.Room.moderator
        case .member: Strings.Room.Manage.member
        }
    }
}
