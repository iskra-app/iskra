import SwiftUI
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
/// The top of it is a portrait: the picture large and centred, the name under it, and one
/// quiet line saying who this is or how many people are here — the shape every messenger uses
/// for a card, and the shape somebody opening this screen is looking for.
///
/// Everything on that portrait is read-only, and the pencil in the corner is where it is changed.
/// It used to be the other way round: the name was a text field and the picture opened a menu, so
/// the screen you read was permanently half in edit mode — a room name one careless tap could
/// empty, and a picture that offered to replace itself when you only wanted a closer look. The
/// pencil appears only for somebody the room actually lets change something, so the screen still
/// shows each reader exactly what they can do; it just no longer asks them to do it by accident.
struct RoomInfoView: View {
    @State private var details: RoomDetailsStore

    /// Leaving takes the whole conversation off the screen, and only whoever owns the
    /// selection can do that — the same shape as sign-out in `RoomListView`.
    var onLeave: () -> Void

    /// Opening the in-chat search from the info screen.
    var onSearch: () -> Void

    @Environment(\.dismiss) private var dismiss

    /// Offline, this screen is a *description* of the room rather than a way to change it. Every
    /// control on it — the name, the topic, the picture, who is in it, whether it is open, and the
    /// way out of it — is a call straight to the server with no queue behind it, so all of them are
    /// turned off rather than left to fail one at a time.
    ///
    /// The fields that change the room have moved to `RoomEditView`, which is disabled offline for
    /// the same reason and one worth spelling out: they commit when they *lose focus*, so a name
    /// typed with no network would sit there looking applied and then be quietly thrown out by a
    /// server that was never asked. Disabled, the field never takes the text in the first place.
    @Environment(\.isOffline) private var isOffline

    /// Whether the editing screen is up. Held here rather than driven by a `NavigationLink`
    /// because `onDisappear` needs to know: pushing a screen takes this one off the display, and
    /// this one's `onDisappear` is what cancels the room subscription.
    @State private var isEditing = false

    @State private var isInviting = false
    @State private var invitee = ""

    /// The person a block has been asked for and not yet confirmed. Blocking is the one
    /// act on this screen with no way back through it.
    @State private var blocking: RoomMemberSummary?
    @State private var isConfirmingLeave = false

    /// The open conversation, for the shared-media screen — its media lives in the loaded timeline.
    /// Optional so the info screen still stands on its own where there is no timeline behind it.
    private let timeline: TimelineStore?

    init(details: RoomDetailsStore, timeline: TimelineStore? = nil, onLeave: @escaping () -> Void, onSearch: @escaping () -> Void) {
        _details = State(initialValue: details)
        self.timeline = timeline
        self.onLeave = onLeave
        self.onSearch = onSearch
    }

    /// A one-to-one chat has no name, no description and no picture of its own — all three
    /// belong to the person you are talking to. Offering to rename them would be offering
    /// something Matrix will happily do and nobody wants.
    ///
    /// Asked of what the room *is*, not of how many people are in it today: invite somebody
    /// into a personal chat and the name, the description and the picture still belong to the
    /// person it was started with, so the screen goes on leaving them alone.
    private var isRoom: Bool { details.kind != .direct }

    var body: some View {
        Form {
            Section {
                identity
                    .profileHeaderRow()
            }

            about

            if let timeline {
                Section {
                    NavigationLink {
                        RoomGalleryView(timeline: timeline)
                    } label: {
                        Label(Strings.Room.sharedMedia, systemImage: "photo.on.rectangle")
                    }
                }
            }

            Section {
                Button {
                    onSearch()
                } label: {
                    Label(Strings.Room.searchInChat, systemImage: "magnifyingglass")
                }
            }

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
        .profileScreen()
        .task { await details.load() }
        .toolbar {
            if canEdit {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isEditing = true
                    } label: {
                        Image(systemName: "pencil")
                            .font(.body.weight(.medium))
                    }
                    .accessibilityLabel(Text(Strings.Room.Manage.edit))
                    // Every field behind the pencil is a call straight to the server. Offline the
                    // screen it opens could show nothing but disabled controls, so the door is shut
                    // instead — the strip at the top of the screen has already said why.
                    .disabled(isOffline)
                }
            }
        }
        .navigationDestination(isPresented: $isEditing) {
            RoomEditView(details: details)
        }
        // The subscription this screen took out on the room goes with the screen. It follows the
        // room as it is renamed from other devices — see `RoomDetailsStore.load()` — and a
        // listener nobody cancels is a listener that runs until the account is signed out.
        //
        // Except when the editing screen is what took this one off the display: the store is
        // handed to it, and a store that stopped listening the moment it was pushed would show
        // a name that no longer followed the room it is renaming.
        .onDisappear {
            guard !isEditing else { return }
            details.stop()
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

    // MARK: - Who or what this room is

    /// The room, at the top: its picture large and centred, its name, and the one line that
    /// says what it is. `ProfileHeader` is shared with settings, so a room and a person are
    /// introduced the same way.
    private var identity: some View {
        ProfileHeader(name: details.name,
                      avatarURL: details.avatarURL,
                      subtitle: subtitle,
                      // A space keeps the square-cornered silhouette it has in the chat list. The
                      // portrait is the largest this picture is ever drawn, and it would be an odd
                      // place for it to change shape.
                      shape: details.kind == .space ? .roundedSquare : .circle,
                      // In a one-to-one chat the line underneath is the other person's Matrix ID,
                      // which is exactly the string someone opens this screen to copy. A count of
                      // participants is not.
                      isSubtitleSelectable: details.isOneToOne)
    }

    /// Whether there is anything behind a pencil worth opening.
    ///
    /// A one-to-one chat has no name, no description and no picture of its own — all three belong
    /// to the person you are talking to, and Matrix will happily let you rename them for yourself,
    /// which is a thing nobody wants. And in a room the three powers are granted separately: the
    /// pencil appears if the room allows any one of them, and the screen it opens shows only the
    /// fields it allows.
    private var canEdit: Bool {
        isRoom && (details.permissions.canRename
                   || details.permissions.canChangeTopic
                   || details.permissions.canChangePicture)
    }

    // MARK: - What it is for, and what it does to your phone

    /// The topic: what the room is for, written by whoever runs it — and nothing at all when
    /// there is none, because an empty section is a heading over a blank. Editing it lives behind
    /// the pencil; this is the reading copy, and it is the same one for everybody.
    @ViewBuilder
    private var about: some View {
        let topic = details.topic ?? ""

        if !topic.isEmpty {
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
        if details.isOneToOne {
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
