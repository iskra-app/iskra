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


    #if os(iOS)
    /// Not on a Mac, where this screen is the root of the info column beside the conversation: a
    /// view there that reads `dismiss` and pushes screens of its own is the shape that spins
    /// `NSHostingView.layout()` forever (see `SettingsView.onClose`). Leaving takes the column away
    /// with the room anyway.
    @Environment(\.dismiss) private var dismiss
    #endif

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
    @State private var ownEditing = false

    /// Handed in where the pencil lives outside this view — the toolbar over the Mac's column, which
    /// has to be declared at the column's root (`RoomInfoColumnToolbar`), not here.
    private var editingBinding: Binding<Bool>?

    private var isEditing: Bool {
        get { editingBinding?.wrappedValue ?? ownEditing }
        nonmutating set {
            if let editingBinding { editingBinding.wrappedValue = newValue } else { ownEditing = newValue }
        }
    }

    /// Which of the room's contents is on show. Not persisted: the tab somebody left open in one
    /// chat is no kind of prediction about the next one.
    @State private var tab: RoomContentTab = .members

    @State private var isInviting = false

    /// The picture pressed in the media tab. Held here rather than in the grid, because the grid is
    /// a run of rows of the form and a sheet hung on those would be one sheet per row.
    @State private var openedMedia: OpenedIndex?

    /// The contacts and the directory "Invite" picks from. Nil only where no session put it up,
    /// and there the tile is not drawn.
    @Environment(\.personalChats) private var personalChats

    /// The person whose page is open, pushed from their row — see `MemberRow`.
    @State private var openedMember: String?
    @State private var isConfirmingLeave = false

    /// The open conversation, for the shared-media screen — its media lives in the loaded timeline.
    /// Optional so the info screen still stands on its own where there is no timeline behind it.
    private let timeline: TimelineStore?

    init(details: RoomDetailsStore, timeline: TimelineStore? = nil, onLeave: @escaping () -> Void,
         onSearch: @escaping () -> Void, isEditing: Binding<Bool>? = nil) {
        _details = State(initialValue: details)
        self.timeline = timeline
        self.onLeave = onLeave
        self.onSearch = onSearch
        self.editingBinding = isEditing
    }

    /// A one-to-one chat has no name, no description and no picture of its own — all three
    /// belong to the person you are talking to. Offering to rename them would be offering
    /// something Matrix will happily do and nobody wants.
    ///
    /// Asked of what the room *is*, not of how many people are in it today: invite somebody
    /// into a personal chat and the name, the description and the picture still belong to the
    /// person it was started with, so the screen goes on leaving them alone.
    private var isRoom: Bool { details.isRoom }

    var body: some View {
        Form {
            // The round buttons under the portrait, in the portrait's own section: a section of
            // their own put the form's gap between sections under the name, and the buttons read as
            // the start of the list rather than as part of who this is. A personal chat is a person:
            // the same tiles their page has from a group's member list, so the two are one screen —
            // Telegram's — rather than two screens about the same person that disagree. A group gets
            // the same row, with "invite" where a person has "share".
            Section {
                identity
                    .profileHeaderRow()
                tiles
            }

            // One block: who the person is, what the chat is for, how loudly it reaches you, and —
            // in a personal chat — the block. One-row sections in a column read as a list that has
            // come apart.
            settings

            #if os(iOS)
            Section { leaveButton }
            #endif

            contents
        }
        .formStyle(.groupedRows)
        .profileScreen()
        .task { await details.load() }
        // Keyed on the rows themselves: an unchanged array compares by its buffer, so a redraw that
        // changed nothing costs nothing, and a page that arrived is sorted once rather than on
        // every one of the body's many readings of the tabs.
        .task(id: timeline?.rows) {
            let rows = timeline?.rows ?? []
            let result = await Task.detached(priority: .userInitiated) { RoomContents(rows: rows) }.value
            guard !Task.isCancelled else { return }
            sorted = result
        }
        .mediaViewer(item: $openedMedia) { opened in
            MediaPager(items: photos, startIndex: opened.value)
        }
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
        #if os(iOS)
        // On a Mac the pencil is over the column instead — see `RoomInfoColumnToolbar`.
        .toolbar {
            if canEdit {
                ToolbarItem(placement: .primaryAction) { editButton }
            }
        }
        #endif
        .navigationDestination(isPresented: Binding(get: { isEditing }, set: { isEditing = $0 })) {
            RoomEditView(details: details)
        }
        .memberProfiles($openedMember, details: details)
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
        // The people to invite are chosen from the same list "New chat" opens on — see `InviteView`.
        .sheet(isPresented: $isInviting) {
            if let personalChats {
                InviteView(details: details, people: personalChats)
                    .listSheetSize()
            }
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
            #if os(iOS)
            dismiss()
            #endif
            onLeave()
        }
    }

    private var editButton: some View {
        RoomInfoEditButton(details: details) { isEditing = true }
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

    /// Telegram's row of round buttons under the portrait.
    ///
    /// In a personal chat: search it, silence it, share the person and show their code — the same
    /// pieces `MemberProfileView` is made of, with the two acts that only make sense from inside
    /// the chat. In a group: search, silence and invite, and for a public one its link and code too,
    /// because a room you can hand to somebody is, for that purpose, the same kind of thing.
    private var tiles: some View {
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

                if isRoom, details.permissions.canInvite, personalChats != nil {
                    ProfileActionTile(title: Strings.Room.Manage.invite,
                                      systemImage: "person.badge.plus",
                                      isBusy: false) {
                        isInviting = true
                    }
                    .disabled(isOffline)
                }

                if let link {
                    ShareLink(item: link.url) {
                        ProfileActionTileLabel(title: Strings.Profile.share, systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.plain)

                    // A code to point a camera at, where a clipboard used to be — see
                    // `MemberProfileView`, whose row this is.
                    ProfileActionTile(title: Strings.QR.title, systemImage: "qrcode", isBusy: false) {
                        isShowingCode = true
                    }
                }
            }
        }
        .padding(.bottom, Theme.Spacing.close)
        .profileHeaderRow()
    }

    /// The Matrix ID, the description, the notifications and the block in a personal chat; the
    /// description and the notifications in a group, where the ID is a room's and the block is per
    /// person, from the member list.
    @ViewBuilder
    private var settings: some View {
        Section {
            if !isRoom, let counterpartID = details.counterpartID {
                MatrixIDField(userID: counterpartID)
            }

            // The description, under the ID — Telegram's "bio" under "username". Nothing at all
            // when there is none: a label over a blank is a field asking to be filled in.
            if let topic = details.topic, !topic.isEmpty {
                ProfileField(title: Strings.Room.about) {
                    // People write paragraphs in a room topic, and they are worth reading.
                    // Selectable, because a topic is where the invite link and the rules tend to live.
                    Text(topic)
                        .textSelection(.enabled)
                }
            }

            Picker(selection: Binding(get: { details.alerts },
                                      set: { choice in Task { await details.setAlerts(choice) } })) {
                ForEach(RoomAlerts.allCases) { choice in
                    Text(Strings.Room.Manage.alerts(choice)).tag(choice)
                }
            } label: {
                Label(String(app: Strings.Room.Manage.alerts), systemImage: alertsIcon)
            }
            .disabled(isOffline)

            // The account's block, for the person this chat is with — see `PersonBlockButton`.
            if !isRoom, let counterpartID = details.counterpartID {
                PersonBlockButton(userID: counterpartID, name: details.name)
            }
        } footer: {
            // Said once, under everything this screen can no longer do, rather than as a grey
            // control the reader is left to interpret. A disabled switch explains nothing on its
            // own; a person who has not noticed the strip at the top of the screen would simply
            // think the app had broken.
            if isOffline {
                Text(Strings.Room.Manage.offline)
            } else if !isRoom, let counterpartID = details.counterpartID,
                      blockStore?.isBlocked(counterpartID) == true {
                Text(Strings.Profile.blockedNotice)
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
                      faces: details.kind == .space ? [] : details.faces,
                      // What the padlock in the header means, in small print directly under the
                      // name — the first thing worth knowing about a chat after who it is.
                      note: details.privacy.explanation,
                      noteIcon: details.privacy.iconName,
                      noteTint: details.privacy == .protected ? .secondary : .orange)
    }

    /// Whether there is anything behind a pencil worth opening.
    ///
    /// In a room the four powers are granted separately: the pencil appears if the room allows any
    /// one of them, and the screen it opens shows only the fields it allows.
    ///
    /// In a personal chat there is always exactly one thing, and it is never refused — what *you*
    /// call the person, on this device. The room's own name, description and picture are not on
    /// offer there and never were: all three belong to the person you are talking to, and Matrix
    /// would happily let you rename them in a way they can read.
    private var canEdit: Bool { details.offersEditing }

    // MARK: - What it is for, and what it does to your phone

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
    private var leaveButton: some View {
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

    @ViewBuilder
    private var contents: some View {
        let tabs = availableTabs

        #if os(macOS)
        // On a Mac a section is a plate whatever its row asks for — `listRowBackground` does not
        // reach it — and a plate around one button, or around a segmented control that is a surface
        // already, is a box with nothing to group. A section's *header* is drawn on the page, so the
        // two single things go there, above the list they lead into.
        if tabs.isEmpty {
            Section { leaveButton }
        } else {
            Section {
                tabContent
            } header: {
                VStack(alignment: .leading, spacing: Theme.Spacing.generous) {
                    leaveButton
                        .textCase(nil)
                    RoomContentPicker(tabs: tabs, selection: Binding(get: { openTab },
                                                                    set: { tab = $0 }))
                        .textCase(nil)
                }
            }
            .edgeToEdge(openTab == .media)
        }
        #else
        if !tabs.isEmpty {
            // The switch is on the page, and what it switches is in a card under it.
            //
            // Not both in one section, which is how it was: a `Form` wraps every row in a plate,
            // so the control came out standing on a white rectangle with a second white rectangle
            // of its own on top of it. A segmented control is already a surface — it is the one
            // piece of furniture on this screen that Apple draws in full — and the plate under it
            // was the app putting a table under a table.
            //
            // The card carries no heading of its own: the name of the open tab is already the
            // highlighted segment right above it, and saying it twice was a title for a title.
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
            }
            // The grid of pictures runs from one edge of the screen to the other, Telegram's
            // contact sheet — not inside the inset card every other section sits in, where three
            // tiles to a row came out as three small stamps with a margin either side.
            .edgeToEdge(openTab == .media)
        }
        #endif
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
            RoomMediaGrid(items: photos) { openedMedia = OpenedIndex(value: $0) }
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

    /// The history sorted into the tabs, worked out once per change of the timeline and off the main
    /// thread — see `RoomContents`.
    @State private var sorted = RoomContents()

    private var photos: [MediaItem] { sorted.photos }
    private var voices: [MediaItem] { sorted.voices }
    private var videoNotes: [MediaItem] { sorted.videoNotes }
    private var files: [MediaItem] { sorted.files }
    private var links: [LinkItem] { sorted.links }

    // MARK: - Who is in it

    @ViewBuilder
    private var members: some View {
        if details.isLoadingMembers && details.members.isEmpty {
            // Not an empty list: a room always has at least us in it, so "no one is here" is never
            // the truth — it only ever means we have not looked yet.
            ProgressView()
                .frame(maxWidth: .infinity)
        } else {
            ForEach(details.members) { member in
                MemberRow(member: member, details: details) { openedMember = member.id }
            }
        }
    }
}

extension RoomDetailsStore {
    /// Anything but a personal chat.
    var isRoom: Bool { kind != .direct }

    /// Whether the pencil is offered: somebody the room lets change something. A personal chat is
    /// always editable — what is changed there is your own name for the person.
    var offersEditing: Bool {
        guard isRoom else { return true }
        return permissions.canRename
            || permissions.canChangeTopic
            || permissions.canChangePicture
            || permissions.canChangeVisibility
            || permissions.canChangeRoles
            || permissions.canChangeHistory
            || permissions.canChangeAddress
            || (permissions.canBan && !banned.isEmpty)
    }
}

/// The pencil, wherever it is put.
private struct RoomInfoEditButton: View {
    let details: RoomDetailsStore
    let action: () -> Void

    @Environment(\.isOffline) private var isOffline

    var body: some View {
        Button(action: action) {
            Image(systemName: "pencil")
                .font(.body.weight(.medium))
        }
        .accessibilityLabel(Text(Strings.Room.Manage.edit))
        // Everything behind it in a room is a call straight to the server, so offline the door is
        // shut rather than opened onto a screen of disabled fields — the strip at the top has
        // already said why. A personal chat's nickname is written to this device and nowhere else,
        // so there is nothing for the network to refuse and the pencil stays live.
        .disabled(isOffline && details.isRoom)
    }
}

#if os(macOS)
/// The pencil and the way out, over the chat's info where it is a column on the right of a Mac
/// window, drawn as the room list's buttons are on the left.
///
/// Over the column only because the column hangs on the split view itself (`InfoColumn`): hung on
/// the conversation's half, the toolbar knew nothing of it and put these beside the chat's header.
/// And only while the column is open — the inspector keeps its content alive after it closes, and
/// a pencil was left in the title bar over nothing.
struct RoomInfoColumnToolbar: ToolbarContent {
    let details: RoomDetailsStore
    let isShown: Bool
    let onEdit: () -> Void
    let onClose: () -> Void

    var body: some ToolbarContent {
        if isShown {
            // Two buttons, not one capsule holding both: leaving and editing are different acts.
            // The way out at the column's leading edge, the pencil at its trailing one.
            ToolbarItem(placement: .primaryAction) {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.body.weight(.medium))
                }
                .accessibilityLabel(Text(Strings.Room.Manage.closeInfo))
            }
            if details.offersEditing {
                toolbarGlassGap(placement: .primaryAction, flexible: true)
                ToolbarItem(placement: .primaryAction) {
                    RoomInfoEditButton(details: details, action: onEdit)
                }
            }
        }
    }
}
#endif
