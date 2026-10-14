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
/// nothing; anyone who wonders what it means presses the name, and the answer is here, directly
/// under the portrait — three words, read at a glance rather than studied.
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

    /// Which of the room's contents is on show. Not persisted: the tab somebody left open in one
    /// chat is no kind of prediction about the next one.
    @State private var tab: RoomContentTab = .members

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

            // A personal chat is a person: the same tiles and the same card their page has from a
            // group's member list, so the two are one screen — Telegram's — rather than two
            // screens about the same person that disagree.
            if !isRoom {
                person
            }

            publicRoomTiles

            about

            // What the padlock means, directly under the name. It used to sit five sections down,
            // between the room's visibility and its notifications, which is filing the one fact on
            // this screen that is about *safety* under housekeeping. Whether a room is encrypted is
            // the first thing worth knowing about it after what it is called.
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
                    .accentControl()
                    .disabled(isOffline)
                }
            }

            // Notifications and search in one block: both are about *your* relationship with this
            // room rather than about the room — how loudly it reaches you, and how you find what
            // was said in it — and two one-row sections in a column read as a list that has come
            // apart rather than as two decisions.
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

                // In a personal chat the search is a tile under the portrait.
                if isRoom {
                    Button {
                        onSearch()
                    } label: {
                        Label(Strings.Room.searchInChat, systemImage: "magnifyingglass")
                    }
                }
            } footer: {
                // Said once, at the top of everything this screen can no longer do, rather than as a
                // grey control the reader is left to interpret. A disabled switch explains nothing on
                // its own; a person who has not noticed the strip at the top of the screen would
                // simply think the app had broken.
                if isOffline {
                    Text(Strings.Room.Manage.offline)
                }
            }

            contents

            // The account's block, for the person this chat is with — at the foot of their page,
            // where it is on every person's page. See `PersonBlockButton`.
            if !isRoom, let counterpartID = details.counterpartID {
                Section {
                    PersonBlockButton(userID: counterpartID, name: details.name)
                }
            }

            Section {
                Button(role: .destructive) {
                    isConfirmingLeave = true
                } label: {
                    Text(isRoom ? Strings.Room.Manage.leave : Strings.Room.Manage.deleteChat)
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
        .sheet(isPresented: $isShowingCode) {
            if let link {
                QRCodeSheet(name: details.name,
                            subtitle: details.counterpartID ?? details.canonicalAlias ?? details.roomID,
                            avatarURL: details.avatarURL,
                            seed: details.kind == .space ? nil : details.avatarSeed,
                            shape: details.kind == .space ? .roundedSquare : .circle,
                            link: link)
            }
        }
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
                    // See `editingNeedsNetwork`.
                    .disabled(isOffline && editingNeedsNetwork)
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
        // Two questions, because there are two acts. Leaving a room is leaving a group of people,
        // and it is reversible by anybody who invites you back. Deleting a personal chat is not
        // leaving anybody — the other person is still there and can still write, and doing so
        // brings the chat back empty, with everything said in it before now gone from this device.
        // A dialog that said "leave" would be describing the group case and quietly mis-describing
        // this one.
        .confirmationDialog(Text(isRoom ? Strings.Room.Manage.leaveQuestion
                                        : Strings.Room.Manage.deleteChatQuestion),
                            isPresented: $isConfirmingLeave,
                            titleVisibility: .visible) {
            Button(String(app: isRoom ? Strings.Room.Manage.leave : Strings.Room.Manage.deleteChat),
                   role: .destructive) {
                Task { await details.leave() }
            }
            Button(String(app: Strings.Room.Manage.cancel), role: .cancel) {}
        } message: {
            Text(isRoom ? Strings.Room.Manage.leaveHelp : Strings.Room.Manage.deleteChatHelp)
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

    // MARK: - The person, in a personal chat

    /// The QR code for this person, or for this room when it is public — see `QRCodeSheet`.
    @State private var isShowingCode = false

    /// What the QR code and "Share" point at: the person in a personal chat; a public room by its
    /// address, or by its ID and the server that knows it when it has none. A private room has no
    /// link worth handing out — anybody scanning it would be turned away at the door.
    private var link: MatrixLink? {
        if !isRoom {
            return details.counterpartID.map(MatrixLink.user)
        }
        guard details.isPublic else { return nil }
        if let alias = details.canonicalAlias {
            return .room(alias, via: [])
        }
        let server = details.roomID.split(separator: ":", maxSplits: 1).dropFirst().first.map(String.init)
        return .room(details.roomID, via: server.map { [$0] } ?? [])
    }

    /// A public room's two tiles: share it, and show its code. The same circles a person's page has,
    /// because a room you can hand to somebody is, for that purpose, the same kind of thing.
    @ViewBuilder
    private var publicRoomTiles: some View {
        if isRoom, let link {
            Section {
                NavigationGlassGroup(spacing: Theme.Spacing.close) {
                    HStack(spacing: Theme.Spacing.close) {
                        ShareLink(item: link.url) {
                            ProfileActionTileLabel(title: Strings.Profile.share, systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.plain)

                        ProfileActionTile(title: Strings.QR.title, systemImage: "qrcode", isBusy: false) {
                            isShowingCode = true
                        }
                    }
                }
                .padding(.vertical, Theme.Spacing.close)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
        }
    }

    /// Telegram's tiles and card under a person's portrait, for the person a personal chat is with.
    /// The same pieces `MemberProfileView` is made of — `ProfileActionTile` and the Matrix ID card —
    /// with the two acts that only make sense from inside the chat: search it, and silence it.
    @ViewBuilder
    private var person: some View {
        Section {
            NavigationGlassGroup(spacing: Theme.Spacing.close) {
                HStack(spacing: Theme.Spacing.close) {
                    ProfileActionTile(title: Strings.Profile.search,
                                      systemImage: "magnifyingglass",
                                      isBusy: false) {
                        onSearch()
                    }

                    let isMuted = details.alerts == .muted
                    ProfileActionTile(title: isMuted ? Strings.Profile.unmute : Strings.Profile.mute,
                                      systemImage: isMuted ? "bell.slash.fill" : "bell.fill",
                                      isBusy: false) {
                        Task { await details.setAlerts(isMuted ? .all : .muted) }
                    }
                    .disabled(isOffline)

                    if let counterpartID = details.counterpartID,
                       let link = MemberProfileView.link(to: counterpartID) {
                        ShareLink(item: link) {
                            ProfileActionTileLabel(title: Strings.Profile.share, systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.plain)
                    }

                    // A code to point a camera at, where a clipboard used to be — see `MemberProfileView`,
                    // whose row this is.
                    if details.counterpartID != nil {
                        ProfileActionTile(title: Strings.QR.title, systemImage: "qrcode", isBusy: false) {
                            isShowingCode = true
                        }
                    }
                }
            }
            .padding(.vertical, Theme.Spacing.close)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        }

        if let counterpartID = details.counterpartID {
            Section {
                LabeledContent {
                    Text(verbatim: counterpartID)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } label: {
                    Text(Strings.Profile.matrixID)
                }
            } footer: {
                if blockStore?.isBlocked(counterpartID) == true {
                    Text(Strings.Profile.blockedNotice)
                }
            }
        }
    }

    /// For the note under the card when this person is blocked.
    @Environment(\.blockStore) private var blockStore

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
                      // A space keeps its initials for the same reason it keeps its square: it is
                      // a shelf of rooms, not somebody.
                      seed: details.kind == .space ? nil : details.avatarSeed,
                      // In a one-to-one chat the line underneath is the other person's Matrix ID,
                      // which is exactly the string someone opens this screen to copy. A count of
                      // participants is not.
                      isSubtitleSelectable: details.isOneToOne,
                      faces: details.kind == .space ? [] : details.faces)
    }

    /// Whether there is anything behind a pencil worth opening.
    ///
    /// In a room the three powers are granted separately: the pencil appears if the room allows any
    /// one of them, and the screen it opens shows only the fields it allows.
    ///
    /// In a personal chat there is always exactly one thing, and it is never refused — what *you*
    /// call the person, on this device. The room's own name, description and picture are not on
    /// offer there and never were: all three belong to the person you are talking to, and Matrix
    /// would happily let you rename them in a way they can read.
    private var canEdit: Bool {
        guard isRoom else { return true }
        return details.permissions.canRename
            || details.permissions.canChangeTopic
            || details.permissions.canChangePicture
    }

    /// Whether the pencil needs the network to be worth pressing.
    ///
    /// Everything behind it in a room is a call straight to the server, so offline the door is shut
    /// rather than opened onto a screen of disabled fields — the strip at the top has already said
    /// why. A personal chat's nickname is written to this device and nowhere else, so there is
    /// nothing for the network to refuse and the pencil stays live.
    private var editingNeedsNetwork: Bool { isRoom }

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

    /// What the padlock in the header means, said plainly. The words come from `IskraCore`, which
    /// is where the app's vocabulary for privacy lives.
    ///
    /// Short on purpose. It used to be a full sentence explaining that nobody outside the chat can
    /// read it, "not even us" — true, well meant, and a paragraph in the position on the screen
    /// where the eye expects a status. A line like that gets read once and then becomes furniture.
    /// The state is the point, so the state is what it says.
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

    // MARK: - What is in it

    /// The room's own contents, behind a strip of tabs: the people, the pictures, the voice notes,
    /// the round videos, the files, the links.
    ///
    /// A tab is only offered when there is something behind it. Six headings over five blanks is a
    /// screen advertising emptiness — and the answer to "are there any files in this chat" is then
    /// given by the strip itself, before anything is pressed.
    ///
    /// What is in them is what the open timeline has loaded, so the strip grows as the history is
    /// paged back. That is the honest arrangement rather than the ideal one: Matrix has no index of
    /// a room's attachments to ask, so the only place the app can count photographs is in the
    /// messages it already holds. "Load earlier" at the bottom of each tab is the same pagination
    /// the conversation uses, and it fills these lists as it goes.
    @ViewBuilder
    private var contents: some View {
        let tabs = availableTabs

        if !tabs.isEmpty {
            // The switch is on the page, and what it switches is in a card under it.
            //
            // Not both in one section, which is how it was: a `Form` wraps every row in a plate,
            // so the control came out standing on a white rectangle with a second white rectangle
            // of its own on top of it. A segmented control is already a surface — it is the one
            // piece of furniture on this screen that Apple draws in full — and the plate under it
            // was the app putting a table under a table.
            //
            // Nothing is lost by separating them, because the card below now carries the name of
            // the open tab as its heading: the two are joined by the word rather than by the
            // plate, which is the stronger join anyway.
            //
            // The binding reads `openTab`, not `tab`. They differ exactly when the tab last pressed
            // is not available — a personal chat opening on `.members`, which it does not have —
            // and binding the raw value there left the control with nothing selected, over a list
            // that plainly belonged to one of the segments.
            Section {
                RoomContentPicker(tabs: tabs, selection: Binding(get: { openTab },
                                                                set: { tab = $0 }))
                    .profileHeaderRow()
            }

            Section {
                tabContent
            } header: {
                Text(openTab.title)
            }
            // The grid of pictures runs from one edge of the screen to the other, Telegram's
            // contact sheet — not inside the inset card every other section sits in, where three
            // tiles to a row came out as three small stamps with a margin either side.
            .edgeToEdge(openTab == .media)
        }
    }

    /// The tabs worth drawing, in a fixed order — the order they are declared in, so a chat that
    /// gains its first file does not reshuffle the strip under somebody's finger.
    private var availableTabs: [RoomContentTab] {
        RoomContentTab.allCases.filter { tab in
            switch tab {
            // Hidden in a personal chat, where the "participants" are you and the person whose name
            // is at the top of the screen. A list of two, one of them yourself, answers a question
            // nobody asked and puts a "remove" menu on the only other person in the conversation.
            case .members: isRoom
            case .media: !photos.isEmpty
            case .voice: !voices.isEmpty
            case .videoNotes: !videoNotes.isEmpty
            case .files: !files.isEmpty
            case .links: !links.isEmpty
            }
        }
    }

    /// The tab actually on show. `tab` is what was last pressed, and what was last pressed can stop
    /// existing — open the files tab, leave the screen, come back to a room whose history has been
    /// reloaded and holds none yet. Falling back to the first tab is what keeps that from drawing a
    /// section with nothing in it.
    private var openTab: RoomContentTab {
        availableTabs.contains(tab) ? tab : (availableTabs.first ?? .members)
    }

    @ViewBuilder
    private var tabContent: some View {
        switch openTab {
        case .members:
            members
        case .media:
            // Edge to edge, Telegram's contact sheet: the month headings keep their own margin.
            RoomMediaGrid(items: photos)
                .profileHeaderRow()
            loadEarlier
        case .voice:
            RoomVoiceList(items: voices)
            loadEarlier
        case .videoNotes:
            RoomVideoNoteList(items: videoNotes)
            loadEarlier
        case .files:
            RoomFileList(items: files)
            loadEarlier
        case .links:
            RoomLinkList(items: links)
            loadEarlier
        }
    }

    /// Reaching further back, from whichever tab is open — by scrolling to the end of it, the way
    /// Telegram's shared media does, and not by a button. It is the conversation's own pagination,
    /// so a page fetched here is a page the chat behind does not have to fetch again.
    ///
    /// There used to be a "Show earlier" button here, which made the reader do by hand, page by
    /// page, what the end of a list already asks for: in a room's old history photos are sparse,
    /// a page of twenty-five events often has none, and the button went on being pressed for
    /// nothing. See `AutoLoadEarlier`.
    @ViewBuilder
    private var loadEarlier: some View {
        if let timeline, timeline.canLoadMore, !timeline.historyIsStranded {
            AutoLoadEarlier(timeline: timeline)
        }
    }

    // MARK: - The history, sorted into tabs

    /// The messages the conversation has loaded, newest first — or none where this screen stands
    /// on its own.
    ///
    /// The timeline holds them the way a conversation reads: oldest at the top, newest at the
    /// bottom, which is right for the chat and backwards for every tab here. Nobody opens the
    /// files tab to find the first file ever sent. Reversed once, at the source, so the six lists
    /// cannot disagree about it — and so a link posted this morning is not eleven screens down.
    private var messages: [Message] {
        let rows = timeline?.rows ?? []
        return rows.reversed().compactMap { row in
            if case let .message(message) = row { message } else { nil }
        }
    }

    private var mediaItems: [MediaItem] { MediaItem.items(from: messages) }
    private var photos: [MediaItem] { mediaItems.filter { $0.kind == .photo || $0.kind == .video } }
    private var voices: [MediaItem] { mediaItems.filter { $0.kind == .voice || $0.kind == .audio } }
    private var videoNotes: [MediaItem] { mediaItems.filter { $0.kind == .videoNote } }
    private var files: [MediaItem] { mediaItems.filter { $0.kind == .file } }
    private var links: [LinkItem] { LinkItem.items(from: messages) }

    // MARK: - Who is in it

    @ViewBuilder
    private var members: some View {
        if isRoom, details.permissions.canInvite {
            Button {
                isInviting = true
            } label: {
                Label(String(app: Strings.Room.Manage.invite), systemImage: "person.badge.plus")
            }
            .disabled(isOffline)
        }

        if details.isLoadingMembers && details.members.isEmpty {
            // Not an empty list: a room always has at least us in it, so "no one is here" is never
            // the truth — it only ever means we have not looked yet.
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
    }
}

/// One person in the room: their face, their name, and what they can do here.
///
/// The row leads to `MemberProfileView`, and the two acts a room allows against somebody — moving
/// them to another rung, taking them out of it — are on a sideways swipe as well. Both, rather than
/// one: a swipe is fast for whoever already knows it is there, and invisible to everybody else, so
/// it is a shortcut to what the profile screen spells out rather than the only way to reach it.
///
/// Nothing is ever shown disabled. What the room refuses simply is not drawn: a greyed-out
/// "Remove" is a promise the homeserver has already broken.
private struct MemberRow: View {
    let member: RoomMemberSummary
    let roles: [RoomRole]
    let canRemove: Bool
    let canBlock: Bool
    let setRole: (RoomRole) -> Void
    let remove: () -> Void
    let block: () -> Void

    @Environment(\.isOffline) private var isOffline

    /// The role picker, asked for by the swipe. A dialog rather than a submenu, because a swipe
    /// action that opened a menu would be a gesture inside a gesture.
    @State private var isChangingRole = false

    /// Every act here is a request to the server with no queue behind it, so offline the row is a
    /// row and nothing else — the swipe is withheld rather than offered and then refused.
    private var canAct: Bool {
        !isOffline && (!roles.isEmpty || canRemove || canBlock)
    }

    var body: some View {
        NavigationLink {
            MemberProfileView(member: member,
                              roles: roles,
                              canRemove: canRemove,
                              canBlock: canBlock,
                              setRole: setRole,
                              remove: remove,
                              block: block)
        } label: {
            HStack(spacing: Theme.Spacing.normal) {
                Avatar(name: member.name, url: member.avatarURL, size: Theme.Size.avatar,
                       seed: member.id)

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
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if canAct {
                if canRemove {
                    Button(role: .destructive, action: remove) {
                        Label(String(app: Strings.Room.Manage.remove), systemImage: "person.badge.minus")
                    }
                }

                if !roles.isEmpty {
                    Button {
                        isChangingRole = true
                    } label: {
                        Label(String(app: Strings.Room.Manage.role), systemImage: "person.badge.key")
                    }
                    .tint(.indigo)
                }
            }
        }
        .confirmationDialog(Text(Strings.Room.Manage.roleQuestion(member.name)),
                            isPresented: $isChangingRole,
                            titleVisibility: .visible) {
            ForEach(roles, id: \.self) { role in
                Button(String(localized: name(of: role))) { setRole(role) }
            }
            Button(String(app: Strings.Room.Manage.cancel), role: .cancel) {}
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

    /// The same three rungs, but named in full — including the one the list leaves blank.
    private func name(of role: RoomRole) -> LocalizedStringResource {
        switch role {
        case .administrator: Strings.Room.administrator
        case .moderator: Strings.Room.moderator
        case .member: Strings.Room.Manage.member
        }
    }
}
