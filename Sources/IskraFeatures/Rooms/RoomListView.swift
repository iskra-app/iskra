import SwiftUI
import IskraCore
import IskraDesign

/// The list of conversations, and the app's home.
///
/// The layout is deliberately quiet: a small centred title, the conversations themselves
/// filling the screen, and the search field floating at the bottom where the thumb already
/// is. Nothing hovers over the list except search — a conversation you want to open should
/// never be behind a button.
///
/// The chrome differs by platform, because the sidebar does. On iPhone the list *is* the
/// screen, so it gets a button in each top corner. On iPad and Mac it is a column standing
/// beside the conversation, and a column that is permanently on screen has no use for a
/// button in each of its corners: both controls sit together on the trailing edge, and the
/// sidebar toggle is gone entirely.
public struct RoomListView: View {
    let session: UserSession
    @Binding var selectedRoomID: String?

    /// The message a search result is asking for. Set alongside the room, and read by `RoomView`,
    /// which goes there and clears it.
    @Binding var selectedEventID: String?

    /// Sign-out unwinds the whole app, not just this screen, so the decision belongs to
    /// whoever owns the session — here it is only reported.
    var onSignOut: () async -> Void
    var onClearedCache: () -> Void

    /// Whether this list is a column beside the conversation rather than the whole screen.
    ///
    /// It has to be told, not measured. Reading `horizontalSizeClass` here would be wrong
    /// and *convincingly* wrong: a `NavigationSplitView` gives each column the size class
    /// its own width earns, so the sidebar reports `.compact` on an iPad in full screen,
    /// while the split view around it is plainly expanded. Only a view outside the split
    /// view sees the window's real size class, so the answer comes down from `IskraRootView`.
    let isSidebar: Bool

    /// Whether the user has asked, in settings, for the Mac's own sidebar rather than this app's
    /// list — see `BetaFeatures` and `BetaView`. Read rather than passed down, because it is a
    /// preference and not a fact about the layout: `isSidebar` above is the layout.
    @AppStorage(BetaFeatures.nativeSidebarKey) private var prefersNativeSidebar = BetaFeatures.nativeSidebarByDefault

    /// The grey lines Settings → Chats leaves out — the last line of a row follows them, as the
    /// chat does. See `RoomListStore.serviceEventSettingsChanged`.
    @AppStorage(ServiceEventSettings.hidesNameChangesKey) private var hidesNameChanges = false
    @AppStorage(ServiceEventSettings.hidesMembershipChangesKey) private var hidesMembershipChanges = false

    @State private var searchText = ""
    @State private var isShowingSettings = false
    @State private var isShowingArchive = false

    /// The chat opened from the archive on a phone — see `ArchiveView.pushed`.
    @State private var archivedRoomID: String?

    /// The space whose rooms are being shown, when one has been tapped.
    @State private var openedSpace: RoomSummary?

    /// The room a "Delete" swipe is asking about. Leaving is not undoable — Matrix has no delete,
    /// only `leave()` — so the swipe arms a confirmation rather than firing straight away.
    @State private var roomToLeave: RoomSummary?

    /// Offline, the app is a *reader*. Everything that would have to ask the server — making a room,
    /// answering an invitation — is turned off rather than left to fail on the last press. Reading
    /// and writing a message still work: a message goes into the send queue and leaves when the
    /// network comes back, which is the one thing here that does not need the server to be there
    /// *now*. See `OfflineBanner`, which is what explains all this on screen.
    @Environment(\.isOffline) private var isOffline

    /// Whether the list has been on the screen long enough for its changes to be animated — see the
    /// `.animation` on the list.
    @State private var hasSettledList = false

    /// What the title says instead of "Chats", when it says anything else — see `RoomListStatus`.
    private var listStatus: RoomListStatus? {
        RoomListStatus(isOffline: isOffline, isUpdating: session.roomList.isUpdating)
    }

    /// The look inside a chat that a long press on its row opens — see `ChatPeek`.
    @Environment(\.chatPeek) private var chatPeek

    /// The recovery flow, when the banner has been tapped. The banner has one reason to exist now —
    /// the history is locked — so there is nothing to carry into the flow but the fact of the tap.
    @State private var isFixingRecovery = false

    /// Which of the two things the "+" was pressed for, and nil when it was not.
    @State private var isStartingChat = false

    public init(session: UserSession,
                selectedRoomID: Binding<String?>,
                selectedEventID: Binding<String?> = .constant(nil),
                isSidebar: Bool,
                onSignOut: @escaping () async -> Void,
                onClearedCache: @escaping () -> Void) {
        self.session = session
        _selectedRoomID = selectedRoomID
        _selectedEventID = selectedEventID
        self.isSidebar = isSidebar
        self.onSignOut = onSignOut
        self.onClearedCache = onClearedCache
    }

    public var body: some View {
        List(selection: selection) {
            if isSearching {
                searchResults
            } else if isNativeSidebar {
                // The same conversations, filed into sections, because that is what a sidebar on
                // a Mac is — see `sectionedRooms` and `isNativeSidebar`.
                sectionedRooms
            } else {
                archiveEntry
                rooms
            }
        }
        .roomListStyle(nativeSidebar: isNativeSidebar)
        // A chat that has just been written in rises to the top the way Telegram's does — it slides
        // up past the ones it overtakes, rather than vanishing from its row and reappearing at the
        // top while every row in between jumps down one. Scoped to the *order* of the list, so a
        // preview or a badge changing in place is not caught by it; and not until the list has been
        // on the screen a moment, so the first conversations do not fly in at launch.
        .animation(hasSettledList ? .smooth(duration: Theme.Timing.chrome * 1.5) : nil,
                   value: session.roomList.rooms.map(\.id))
        .onChange(of: hidesNameChanges) { session.roomList.serviceEventSettingsChanged() }
        .onChange(of: hidesMembershipChanges) { session.roomList.serviceEventSettingsChanged() }
        .onChange(of: session.roomList.rooms.isEmpty, initial: true) { _, isEmpty in
            guard !isEmpty, !hasSettledList else { return }
            Task {
                try? await Task.sleep(for: Theme.Timing.timelineSettles)
                hasSettledList = true
            }
        }
        // An invitation that would not be accepted or declined. The same apology every other
        // refusal in the app gets — see `FailureAlert`.
        .failureAlert(Bindable(session.roomList).failure)
        // "Waiting for network…" or "Updating…" in place of the title while the list is not simply
        // current — Telegram's. In the bar's middle with a spinner on iPhone; in a sidebar, where
        // the title is plain text, the words alone. See `RoomListStatus`.
        .navigationTitle(Text(listStatus?.title ?? Strings.RoomList.title))
        // A small title, centred, in the bar itself — not the large scrolling headline
        // SwiftUI would otherwise give this screen. `toolbarTitleDisplayMode` says that
        // on iOS and on the Mac; `navigationBarTitleDisplayMode` would only say it on iOS.
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            if hasSidebarChrome {
                ToolbarItem(placement: .primaryAction) { newConversationMenu }
                ToolbarItem(placement: .primaryAction) { settingsButton }
            } else {
                ToolbarItem(placement: .principal) { RoomListTitle(status: listStatus) }
                ToolbarItem(placement: .navigation) { newConversationMenu }
                // Its own glass, not the bar's — see `accountButton`.
                ToolbarItem(placement: .primaryAction) { accountButton }
                    .outsideToolbarGlass()
            }
        }
        // Nothing to remove on iPhone — a collapsed split view never shows the toggle —
        // so this only bites where it is meant to, on iPad and Mac.
        //
        // The native sidebar does not get it back either, and that is deliberate. This app is a
        // chat client: the list of conversations is not a panel of options beside the document,
        // it is one of the two halves of the window, and a button whose whole job is to take one
        // of those halves away earns its place in Xcode and not here. What is left is the system's
        // sidebar *look* without the system's assumption about what a sidebar is for.
        .toolbar(removing: .sidebarToggle)
        .roomListSearch(text: $searchText, nativeSidebar: isNativeSidebar)
        // Scrolling the results puts the keyboard away — it covers half of them otherwise.
        .scrollDismissesKeyboard(.immediately)
        // And the same reasoning at the other end. The banner is in the way *on purpose* — it is
        // about messages the user cannot read, or a code that is one lost phone away from mattering
        // very much — but being in the way is not the same as sitting on top of the first
        // conversation, which is what an overlay would have done.
        .safeAreaInset(edge: .top) {
            RecoveryBanner(recovery: session.recovery) {
                isFixingRecovery = true
            }
        }
        // A session this device has not seen before — "was this you?". Under the recovery banner,
        // because it is the same kind of interruption, and somebody in the account who should not
        // be is worth it. See `NewSignInBanner`.
        .newSignIns(for: session)
        .sheet(isPresented: $isFixingRecovery) {
            // With a way out, unlike the copy of this the root puts up after signing in. There it is
            // a gate; here it is a sheet somebody opened out of curiosity about a banner, and a
            // curious person must be allowed to leave. The banner does not go anywhere — it will ask
            // again tomorrow, which is its whole job.
            RecoverySetupView(session: session,
                              onCancel: { isFixingRecovery = false },
                              onDone: { isFixingRecovery = false })
        }
        // And the same again at the top when the network is gone — see `OfflineBanner`, which is an
        // inset for exactly the reason the search field is one. On every device, iPhone included:
        // the title's "Waiting for network…" is a word in the bar, and the strip is the thing that
        // cannot be missed.
        .offlineBanner()
        .overlay { emptyState }
        // A real destination on this column's stack, not a view swapped in behind a
        // hand-rolled transition. That is what buys the stock push, the back button and
        // the swipe back — none of which is worth reimplementing, and all of which is
        // noticeably wrong when you do.
        // Leaving is the one swipe that cannot be taken back, so it asks first — and says the true
        // thing, that "delete" here means leaving a room you cannot delete.
        .confirmationDialog(Text(Strings.RoomList.Swipe.leaveConfirmTitle),
                            isPresented: Binding(get: { roomToLeave != nil },
                                                 set: { if !$0 { roomToLeave = nil } }),
                            titleVisibility: .visible,
                            presenting: roomToLeave) { room in
            Button(String(app: Strings.RoomList.Swipe.leaveConfirm), role: .destructive) {
                Task { await session.roomList.leave(roomID: room.id) }
                roomToLeave = nil
            }
            Button(String(app: Strings.RoomList.Swipe.cancel), role: .cancel) {
                roomToLeave = nil
            }
        } message: { _ in
            Text(Strings.RoomList.Swipe.leaveConfirmMessage)
        }
        .navigationDestination(item: $openedSpace) { space in
            SpaceRoomsView(space: space, session: session) { roomID in
                // Opening a room from inside a space selects it in the detail column and closes the
                // space screen — you came here to find a room, and you found it.
                selectedRoomID = roomID
                openedSpace = nil
            }
        }
        .navigationDestination(isPresented: $isShowingArchive) {
            // Beside the archive on iPad and Mac: the chat goes to the detail column, as from the main
            // list. On a phone the archive pushes the chat itself (`pushed`). Selecting it there —
            // which is what this did — asks the collapsed split view to show its detail column, and
            // it does that by unwinding the sidebar's stack, archive and all: no slide in, and Back
            // landed in the main list.
            ArchiveView(session: session,
                        onOpen: { roomID in
                            if isSidebar {
                                selectedRoomID = roomID
                            } else {
                                archivedRoomID = roomID
                            }
                        },
                        pushed: isSidebar ? nil : $archivedRoomID)
            #if os(macOS)
            // Escape puts the archive away, as it closes anything else on a Mac. A key equivalent,
            // like the conversation's own (`RoomView`), and switched off while a conversation is
            // open beside it: then the first Escape closes the chat and the second the archive,
            // rather than the two shortcuts fighting over one key.
            .background {
                Button("") { isShowingArchive = false }
                    .keyboardShortcut(.cancelAction)
                    .disabled(selectedRoomID != nil)
                    .opacity(0)
                    .accessibilityHidden(true)
            }
            #endif
        }
        .navigationDestination(isPresented: $isShowingSettings) {
            // In a sidebar the system pushes without giving the pushed screen a way back,
            // so settings has to draw its own. On iPhone it must not — there is already
            // one in the corner.
            SettingsView(session: session,
                         onSignOut: onSignOut,
                         onClearedCache: onClearedCache,
                         showsBackButton: isSidebar,
                         // The way out, given rather than taken from the environment — and the
                         // reason why is worth the line: see `SettingsView.onClose`.
                         onClose: { isShowingSettings = false })
        }
        // A sheet, not a push: creating a chat is a question with a Cancel, and the answer
        // to it replaces what is *behind* this column — so it is a thing you put down, not
        // a place you go back from.
        .sheet(isPresented: $isStartingChat) {
            NewChatView(session: session) { roomID in
                // Openable already: creating and joining both wait for the SDK to have the
                // room, so selecting it here does not race the sync that will put it in the
                // list a moment later. See `UserSession.timeline(forRoomID:)`.
                selectedRoomID = roomID
                isStartingChat = false
            }
        }
        .onChange(of: searchText) { _, query in
            session.search.search(query)
        }
    }

    /// The selection, less the one tap that is not a choice: the finger that held a row for a peek,
    /// coming back up off it. See `ChatPeekPresenter.isPeeking(at:)` — let through, it would open
    /// the chat under the card and read the very messages the peek promised to leave alone.
    private var selection: Binding<String?> {
        Binding(get: { selectedRoomID },
                set: { roomID in
                    if let roomID, chatPeek?.isPeeking(at: roomID) == true { return }
                    selectedRoomID = roomID
                })
    }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Whether the bar carries the sidebar's buttons — "+" beside the gear — or the phone's: "+" at
    /// the left, the face at the right.
    ///
    /// Never the sidebar's on an iPhone, whatever the size class says. An iPhone is `.regular`
    /// wide in landscape on the big models, and for a moment whenever the system draws the app
    /// sideways for the app switcher — and the list, told it was a sidebar, moved its "+" over to
    /// the right beside a gear the phone never shows, and left it there when it came back.
    private var hasSidebarChrome: Bool {
        #if os(iOS)
        isSidebar && UIDevice.current.userInterfaceIdiom != .phone
        #else
        isSidebar
        #endif
    }

    /// Whether this list is drawn as the Mac's own sidebar.
    ///
    /// Three conditions and all three matter. The platform, because the thing being imitated only
    /// exists on one of them. `isSidebar`, because a sidebar that is the whole screen is not a
    /// sidebar — and this is why the flag is checked here rather than switched on globally.
    /// And the preference, because it is an experiment somebody opted into.
    private var isNativeSidebar: Bool {
        BetaFeatures.hasAnything && isSidebar && prefersNativeSidebar
    }

    // MARK: - Chrome

    /// The "+": top-left on iPhone, beside the gear on iPad and Mac. Opens "New chat".
    private var newConversationMenu: some View {
        Button {
            isStartingChat = true
        } label: {
            Image(systemName: "plus")
                .font(.body.weight(.medium))
        }
        .accessibilityLabel(Text(Strings.RoomList.newConversation))
        // Not disabled offline any more, though making a room still needs the server: the screen
        // behind it is also the list of everybody you already write to, and opening one of those
        // conversations needs nothing but the local store.
    }

    /// The user's own face, top right — the iPhone's way into settings, and the twin of the
    /// chat's picture at the same corner of a room. Same glass, same ring, same reason: the
    /// toolbar's shared background is hidden at the item and the circle is drawn here instead,
    /// cut to the picture, because a shared background comes with the bar's own margins and
    /// leaves a sliver of glass down either side of anything round. See `RoomAvatarButton`.
    private var accountButton: some View {
        Button {
            isShowingSettings = true
        } label: {
            Avatar(name: session.displayName,
                   url: session.avatarURL,
                   size: Theme.Size.avatarToolbar,
                   seed: session.userID)
                .padding(Theme.Spacing.tight)
                .navigationGlass(in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(Strings.Account.settings))
        .accountMenu()
    }

    /// A gear, top right, on iPad and Mac. A face reads as *you* — a fine thing to tap on a
    /// phone, where the account is the whole of settings. Sat next to the "+" in a sidebar
    /// it would read as one more piece of chrome, and a chat client is full of faces already.
    /// It also matches the "+" in weight, which two round portraits never would.
    private var settingsButton: some View {
        Button {
            isShowingSettings = true
        } label: {
            Image(systemName: "gearshape")
                .font(.body.weight(.medium))
        }
        .accessibilityLabel(Text(Strings.Account.settings))
        .accountMenu()
    }

    // MARK: - Content

    @ViewBuilder
    private var rooms: some View {
        let rooms = session.roomList.rooms
        ForEach(Array(rooms.enumerated()), id: \.element.id) { index, room in
            row(for: room)
                .separatorsBetweenRowsOnly(isFirst: index == 0, isLast: index == rooms.count - 1)
        }
    }

    /// One conversation, in whichever of its three shapes it is.
    ///
    /// Pulled out of `rooms` so the sectioned sidebar can draw the same rows — see
    /// `sectionedRooms`. Two lists that agree about what a room *is* and disagree only about how
    /// they are ordered is the point; two lists with two copies of this would drift apart at the
    /// first swipe action added to one of them.
    @ViewBuilder
    private func row(for room: RoomSummary) -> some View {
        Group {
                if room.isInvitation {
                    // Deliberately *not* tagged. A tagged row in a `List(selection:)` is a row you
                    // can open, and there is nothing to open: you are not in this room, its
                    // timeline is empty, and anything typed into it is refused by the server. That
                    // is precisely what used to happen — an invitation arrived, rendered as an
                    // ordinary chat, and led into a dead conversation with no explanation. A
                    // question is answered, not entered.
                    InviteRow(room: room,
                              onAccept: { Task { await session.roomList.accept(roomID: room.id) } },
                              onDecline: { Task { await session.roomList.decline(roomID: room.id) } })
                } else if room.isSpace {
                    // A space is not a chat, so it does not select one: tapping it opens the list of
                    // rooms *inside* it. Not `.tag`-selectable for the same reason an invitation is
                    // not — there is no conversation here to open.
                    Button {
                        openedSpace = room
                    } label: {
                        RoomRow(room: room,
                                isTyping: session.roomList.typingRoomIDs.contains(room.id),
                                compact: isNativeSidebar)
                    }
                    .buttonStyle(.plain)
                    .roomListSwipeActions(room: room,
                                          roomList: session.roomList,
                                          onLeave: { roomToLeave = room })
                } else {
                    RoomRow(room: room,
                                isTyping: session.roomList.typingRoomIDs.contains(room.id),
                                compact: isNativeSidebar)
                        .tag(room.id)
                        .roomListSwipeActions(room: room,
                                              roomList: session.roomList,
                                              onLeave: { roomToLeave = room })
                        .chatPeek(room, session: session) { selectedRoomID = room.id }
                }
        }
        // What the row says is read off the chat itself while it is on the screen — the deleted
        // message, the grey line, the eye on a message read. See `RoomPeek`.
        .onAppear { session.roomList.rowAppeared(room.id) }
        .onDisappear { session.roomList.rowDisappeared(room.id) }
    }

    /// The conversations filed into sections, for the native sidebar only.
    ///
    /// The app's own list is deliberately unsorted: it shows what the server sends, most recent
    /// first, which is the order a chat app is read in and the order every chat app uses. A Mac
    /// sidebar is a different object — it is a place where things are *kept*, every Mac app keeps
    /// them under headings, and a sidebar that refused to would read as unfinished rather than as
    /// principled. So the headings exist here and only here.
    ///
    /// Within each section the server's order survives untouched, so a section is a filter and
    /// never a re-sort: the busiest conversation is still at the top of the one it belongs to.
    @ViewBuilder
    private var sectionedRooms: some View {
        let all = session.roomList.rooms
        let invitations = all.filter(\.isInvitation)
        let spaces = all.filter { $0.isSpace && !$0.isInvitation }
        let chats = all.filter { !$0.isSpace && !$0.isInvitation }
        let pinned = chats.filter(\.isPinned)
        let unpinned = chats.filter { !$0.isPinned }

        // At the top, where the plain list and Telegram both keep it. It used to sit at the
        // bottom here, on the theory that a Mac sidebar files the shelf you rarely open under
        // everything you do — and under a few hundred chats that put it where nobody would ever
        // scroll to find it.
        if !session.roomList.archivedRooms.isEmpty {
            Section { archiveEntry.sidebarRowInsets() }
        }

        // Then invitations, because they are a question waiting for an answer rather than a place
        // to read.
        if !invitations.isEmpty {
            section(invitations, titled: Strings.RoomList.Sidebar.invitations)
        }

        if !spaces.isEmpty {
            section(spaces, titled: Strings.RoomList.Sidebar.spaces)
        }

        // Pinned conversations get a heading of their own rather than a pin drawn on a row in one
        // long list. That is the difference the sidebar is for: on a phone the pin is a mark on a
        // chat, here it is a shelf the chat is kept on.
        if !pinned.isEmpty {
            section(pinned, titled: Strings.RoomList.Sidebar.pinned)
        }

        // Unheaded when it is the only thing on screen. A lone "Chats" over every conversation
        // there is names nothing — there is nothing it tells them apart from — so the heading
        // appears the moment something else does.
        let isAlone = invitations.isEmpty && spaces.isEmpty && pinned.isEmpty
        section(unpinned, titled: isAlone ? nil : Strings.RoomList.Sidebar.chats)

    }

    /// One heading and the conversations under it — or, with no title, the conversations alone.
    ///
    /// The two shapes are spelled out rather than handed a header that is sometimes `EmptyView`:
    /// an empty header is still a header as far as the list is concerned, and it leaves a gap
    /// above the first row where a heading was not.
    @ViewBuilder
    private func section(_ rooms: [RoomSummary], titled title: LocalizedStringResource?) -> some View {
        if let title {
            Section {
                ForEach(rooms, id: \.id) { row(for: $0).sidebarRowInsets() }
            } header: {
                Text(title)
            }
        } else {
            Section {
                ForEach(rooms, id: \.id) { row(for: $0).sidebarRowInsets() }
            }
        }
    }

    /// The way into the archive, shown only when there is something in it. A quiet row at the top of
    /// the list — the same place Telegram keeps it — rather than a permanent piece of chrome for a
    /// shelf that is usually empty.
    @ViewBuilder
    private var archiveEntry: some View {
        if !session.roomList.archivedRooms.isEmpty {
            Button {
                isShowingArchive = true
            } label: {
                Label(String(app: Strings.RoomList.Archive.title),
                      systemImage: "archivebox")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    // The whole width of the row is the button, not only the words in it: a row
                    // that looks like a row and answers only where its label happens to end is
                    // a row people tap twice.
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            // Nothing drawn above it. It is the first thing under the title, and a rule there is
            // a line under an edge that already exists.
            .listRowSeparator(.hidden, edges: .top)
        }
    }

    @ViewBuilder
    private var searchResults: some View {
        let hits = session.search.hits
        ForEach(Array(hits.enumerated()), id: \.element.id) { index, hit in
            Button {
                // The room *and* the message. A search that finds a sentence from March and then
                // drops you at the bottom of today's conversation has not answered the question —
                // it has only told you which room to go looking in. `hit.id` is the event, and
                // `RoomView` scrolls to it, paginating the history back until it is there to be
                // scrolled to.
                selectedEventID = hit.id
                selectedRoomID = hit.roomID
            } label: {
                VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                    Text(hit.senderName)
                        .font(.subheadline.weight(.semibold))
                    Text(hit.excerpt)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .buttonStyle(.plain)
            .separatorsBetweenRowsOnly(isFirst: index == 0, isLast: index == hits.count - 1)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if isSearching, session.search.foundNothing, !session.search.isSearching {
            ContentUnavailableView.search(text: searchText)
        } else if !isSearching, session.roomList.rooms.isEmpty {
            if session.roomList.isLoadingInitialRooms {
                RoomListSkeleton()
            } else {
                ContentUnavailableView(String(app: Strings.RoomList.emptyTitle),
                                       systemImage: "bubble.left.and.bubble.right",
                                       description: Text(Strings.RoomList.emptyMessage))
            }
        }
    }
}

private extension View {
    /// The list's own look, or the Mac's.
    ///
    /// `.plain` is the app's: flat rows, hairlines drawn by hand between them, and a row that fills
    /// its width. `.sidebar` is what every Mac app's source list is made of — inset rows, a rounded
    /// selection that follows the accent, collapsible headings, and the sidebar material behind all
    /// of it. Neither is reachable from the other by tweaking: they are two list styles, so this is
    /// two branches rather than a value.
    ///
    /// Flipping the switch changes the identity of the view underneath, which rebuilds the list.
    /// That is the right trade here — the switch is thrown once, in settings, by somebody who is
    /// looking at the list precisely to see it change.
    @ViewBuilder
    func roomListStyle(nativeSidebar: Bool) -> some View {
        if nativeSidebar {
            listStyle(.sidebar)
        } else {
            listStyle(.plain)
        }
    }

    /// Where the search field goes.
    ///
    /// The app's own is a floating field at the *bottom*, which is where a thumb already is — see
    /// `RoomSearchField`. That reasoning is about a phone and does not survive the trip to a Mac,
    /// where there is no thumb and where search has sat at the top of the sidebar since Mail had a
    /// sidebar. `.searchable(placement: .sidebar)` is the system's own field in the system's own
    /// place, which also buys ⌘F and the toolbar's focus ring for free.
    @ViewBuilder
    func roomListSearch(text: Binding<String>, nativeSidebar: Bool) -> some View {
        if nativeSidebar {
            searchable(text: text,
                       placement: .sidebar,
                       prompt: Text(Strings.RoomList.searchPrompt))
        } else {
            // An inset rather than an overlay: this reserves the space, so the last conversation
            // can still be scrolled clear of the search field instead of living underneath it
            // forever.
            safeAreaInset(edge: .bottom) {
                RoomSearchField(text: text)
            }
        }
    }

    /// A row in the Mac sidebar, padded more tightly than the list would pad it.
    ///
    /// A row trait, so it goes on each row rather than on the `List` — and that is the whole
    /// reason this is a named modifier instead of one line at the top of the screen: it has to be
    /// said in three places, and a fourth section added later that forgets it would be the one
    /// with a different rhythm. See `Theme.Spacing.sidebarRow` for why it is tighter.
    ///
    /// Nothing at all vertically and the smallest step sideways. The sides are not zero because
    /// the first thing on a row is a circle: flush against the capsule's own rounded edge, a face
    /// reads as having been cropped by it, and four points is the least that keeps the two curves
    /// apart. The rest of the row's breathing room is the sidebar's own margin, further out.
    func sidebarRowInsets() -> some View {
        listRowInsets(EdgeInsets(top: Theme.Spacing.sidebarRow,
                                 leading: Theme.Spacing.tight,
                                 bottom: Theme.Spacing.sidebarRow,
                                 trailing: Theme.Spacing.tight))
    }
}

/// One conversation in the list. Internal, not private, so the archive screen renders its rows the
/// same way the main list does — an archived chat should look like exactly what it is.
struct RoomRow: View {
    let room: RoomSummary

    /// Somebody in the room is writing — said instead of the last message. See
    /// `RoomListStore.typingRoomIDs`.
    var isTyping = false

    /// Whether this row is standing in the Mac's own sidebar, where it has to be shorter.
    ///
    /// One line of the last message instead of two, and no space reserved for the second. In the
    /// app's own list the reserved line is load-bearing — see `lineLimit` below — but a sidebar is
    /// a narrow column read down its length, and a band of empty space under every message is
    /// exactly the padding that makes a list of eight conversations look like a list of five.
    ///
    /// The rows stay the same height as each other regardless, which is what the reserved line was
    /// protecting: with one line of preview the tallest thing in the row is the face beside it, and
    /// a face is the same size in every row there is.
    var compact = false

    /// For the pin, which is the one coloured thing on this row. See `body`.
    @Environment(\.accent) private var accent
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: Theme.Spacing.normal) {
            // A space wears a square-cornered face so it reads as a space, not a chat, before its
            // name is even read — see `AvatarShape`.
            // A space is a shelf of rooms rather than somebody to look at, so it gets no
            // creature — only the square and its initials.
            RoomAvatar(name: room.name, url: room.avatarURL, size: Theme.Size.roomAvatar,
                       shape: room.isSpace ? .roundedSquare : .circle,
                       seed: room.isSpace ? nil : room.avatarSeed,
                       faces: room.faces)

            VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                HStack(spacing: Theme.Spacing.tight) {
                    Text(room.name)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)

                    // A closed lock is the only encryption vocabulary on this screen.
                    if room.privacy == .protected {
                        Image(systemName: "lock.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(Text(Strings.RoomList.privateChat))
                    }

                    Spacer(minLength: 0)

                    // Pinned chats wear a pin, and it is at *this* end of the row rather than
                    // tucked in beside the name, where it spent a while being missed entirely.
                    // Two reasons it was invisible there: it sat immediately after a padlock, in
                    // the same grey at the same caption-two size, so the eye read the pair as one
                    // smudge of chrome; and a name long enough to truncate pushed it up against
                    // the ellipsis, which is the least legible place on the line. Here it stands
                    // beside the timestamp with nothing else around it, tinted rather than grey —
                    // the row's one piece of *status*, which is what being pinned is. Same shape
                    // the swipe action uses, so the gesture and its result say the same word.
                    if room.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption)
                            .foregroundStyle(accent.color)
                            .accessibilityLabel(Text(Strings.RoomList.pinned))
                    }

                    // How far your own last message has got, beside its time — Telegram's place
                    // for it. The same marks the conversation draws (`DeliveryTick`).
                    if let mark = room.lastMessageMark, !isTyping {
                        lastMessageMark(mark)
                    }

                    if let date = room.lastActivity {
                        // See `RoomTimestamp`: not `.relative`, which says "-3 мин" in Russian and
                        // then goes on saying it for an hour.
                        Text(RoomTimestamp.label(for: date))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // Top-aligned, because the preview is now two lines and the badge is one: centred,
                // it would drift down beside a long message and sit level with the middle of a
                // sentence rather than with the row it belongs to.
                HStack(alignment: .top, spacing: Theme.Spacing.close) {
                    // "печатает…" in place of the last message while somebody is writing, in the
                    // accent — the one moment the preview is news rather than history.
                    preview
                        .font(.subheadline)
                        .foregroundStyle(isTyping ? AnyShapeStyle(accent.color) : AnyShapeStyle(.secondary))
                        .contentTransition(.opacity)
                        .animation(.smooth(duration: Theme.Timing.chrome), value: isTyping)
                        // Two lines, and the space for both is kept even when only one is used.
                        //
                        // Without `reservesSpace` a list of chats has rows of two different
                        // heights, depending on how long each last message happens to be — and the
                        // eye reads that ragged column as the list being *sorted* by something,
                        // which it is not. A steady row is what lets the faces beside them scan as
                        // a column at all.
                        //
                        // In the sidebar one line, and nothing reserved — see `compact`. The rows
                        // are still all one height there, because the face is then the tallest
                        // thing in them.
                        .lineLimit(compact ? 1 : 2, reservesSpace: !compact)

                    Spacer(minLength: 0)

                    if room.hasUnread || room.hasUnreadReactions {
                        HStack(spacing: Theme.Spacing.tight) {
                            // Somebody reacted. A heart of its own, and never a number on the
                            // badge — a reaction is an answer to something already read, and
                            // counting it as a message sent people into chats that had nothing
                            // new in them. Telegram's mark, in Telegram's red.
                            if room.hasUnreadReactions {
                                Image(systemName: "heart.fill")
                                    .font(.system(size: Theme.Size.unreadBadge * 0.5, weight: .bold))
                                    .foregroundStyle(.white)
                                    .frame(width: Theme.Size.unreadBadge, height: Theme.Size.unreadBadge)
                                    .background(room.isMuted ? Color.gray : Color.red, in: Circle())
                            }

                            // Somebody named you, or answered you. It used to turn the whole badge
                            // red, and red in a list of chats reads as an *error* — so it is its
                            // own mark now, an "@" beside the count, in the same colour as the
                            // count. What it says is who the messages are for, not how alarmed
                            // to be about them.
                            if room.isMentioned {
                                Image(systemName: "at")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(accent.foreground(in: colorScheme))
                                    .frame(width: Theme.Size.unreadBadge, height: Theme.Size.unreadBadge)
                                    .background(mentionFill, in: Circle())
                            }

                            // A count, not a sentence — but still formatted for the locale
                            // rather than interpolated, so the digits are the right ones.
                            //
                            // Two colours — see `UnreadEmphasis`. The accent for a chat that
                            // notifies you, grey for one you silenced: grey is a thing worth
                            // saying, and the accent carries the ordinary case. On the mono theme
                            // the accent is the foreground itself — black in the light, white in
                            // the dark — with the page's colour written on it.
                            //
                            // A number when there is one to show, and a dot when there is not.
                            // A muted room counts no notifications and still has new messages in
                            // it, and a room flagged unread by hand has none at all — both used to
                            // draw a badge with **0** written in it.
                            Group {
                                if room.hasUnreadCount {
                                    Text(room.unreadNotifyingMessages, format: .number)
                                        .font(.caption.weight(.semibold).monospacedDigit())
                                        .foregroundStyle(badgeInk)
                                        .padding(.horizontal, 7)
                                        .frame(minWidth: Theme.Size.unreadBadge,
                                               minHeight: Theme.Size.unreadBadge)
                                } else if room.hasUnread && !room.isMentioned {
                                    Circle().fill(.clear).frame(width: Theme.Size.unreadDot, height: Theme.Size.unreadDot)
                                }
                            }
                            .background(room.hasUnread ? badgeFill : AnyShapeStyle(.clear), in: Capsule())
                        }
                    }
                }
            }
        }
        // The row's own height, rather than the one `List` gives it.
        //
        // Most of the gap between two chats was never ours: it is the system's row inset, and it
        // is generous because it is sized for a single line of text — a settings row, a name in a
        // list. A chat row is three lines tall on its own and does not need the same air around it,
        // and with the faces enlarged the column of them was reading as a list of *cards* with the
        // conversations a long way apart. Set here rather than at the `List`, so the invitation
        // rows — which carry two buttons and genuinely want the room — keep the system's.
        .listRowInsets(EdgeInsets(top: Theme.Spacing.normal,
                                  leading: Theme.Spacing.roomy,
                                  bottom: Theme.Spacing.normal,
                                  trailing: Theme.Spacing.roomy))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    /// The last message, with the icon of what it is in front of it when it is an attachment —
    /// a photo, a voice message, a sticker. Part of the same `Text`, so the two lines wrap as one.
    private var preview: Text {
        if isTyping { return Text(Strings.Room.typing) }
        let words = Text(room.lastMessage ?? " ")
        guard let symbol = room.lastMessageKind.map(Self.symbol(for:)) else { return words }
        return Text(Image(systemName: symbol)) + Text(verbatim: " ") + words
    }

    static func symbol(for kind: PreviewKind) -> String {
        switch kind {
        case .photo: "photo"
        case .video: "video"
        case .videoNote: "video.circle"
        case .voice: "mic"
        case .audio: "music.note"
        case .file: "doc"
        case .location: "mappin.and.ellipse"
        case .sticker: "face.smiling"
        case .poll: "chart.bar"
        }
    }

    @ViewBuilder
    private func lastMessageMark(_ mark: LastMessageMark) -> some View {
        Group {
            switch mark {
            case .sending:
                Image(systemName: "clock")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(Text(Strings.Message.Delivery.sending))
            case .sent:
                Image(systemName: "checkmark")
                    .foregroundStyle(accent.color)
                    .accessibilityLabel(Text(Strings.Message.Delivery.sent))
            case .read:
                Image(systemName: "eye.fill")
                    .foregroundStyle(accent.color)
                    .accessibilityLabel(Text(Strings.Message.Delivery.read))
            case .failed:
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
                    .accessibilityLabel(Text(Strings.Message.Delivery.failed))
            }
        }
        .font(.caption)
    }

    /// One sentence, so VoiceOver reads a row as a thought rather than as a pile of
    /// fragments.
    private var accessibilityLabel: String {
        var parts = [room.name]
        if room.privacy == .protected {
            parts.append(String(app: Strings.RoomList.privateChat))
        }
        if room.isPinned {
            parts.append(String(app: Strings.RoomList.pinned))
        }
        if let message = room.lastMessage { parts.append(message) }

        // Both, when both are true, and that is the fix rather than a flourish. These used to be
        // an either/or: a mention suppressed the unread count entirely, so a room with twelve
        // unread messages and one mention in them showed a red **12** on screen and told VoiceOver
        // "1 mention". The badge and the voice were reading different numbers off the same row,
        // and the one you could not see was the one leaving twelve messages out.
        if room.hasUnreadCount {
            parts.append(String(app: Strings.RoomList.unread(room.unreadNotifyingMessages)))
        } else if room.hasUnread {
            // Unread with nothing to count — a muted room, or one flagged by hand. "0 unread"
            // is what the counted sentence would have said, and it is the opposite of true.
            parts.append(String(app: Strings.RoomList.hasUnread))
        }
        if room.isMentioned {
            parts.append(String(app: Strings.RoomList.mentions(room.mentionCount)))
        }
        if room.hasUnreadReactions {
            parts.append(String(app: Strings.RoomList.reactions(room.unreadReactionCount)))
        }
        return parts.joined(separator: ", ")
    }

    /// What the badge is filled with: the accent itself — `.primary` on the mono theme, which is
    /// the black-and-white pair — or a solid grey for a room the user silenced.
    ///
    /// A solid grey, not a translucency of the foreground: a muted room is almost always the dot
    /// case, and nine percent of the foreground ten points across is a smudge.
    private var badgeFill: AnyShapeStyle {
        switch room.unreadEmphasis {
        case .ordinary: AnyShapeStyle(accent.color)
        case .muted: AnyShapeStyle(Color.gray)
        }
    }

    /// And what is written on it. The pair to `badgeFill`: each fill comes with the one thing that
    /// stays readable on it — `foreground(in:)` rather than `foreground`, because on mono the
    /// latter is `.background`, which resolves against whatever it happens to be drawn into.
    private var badgeInk: AnyShapeStyle {
        switch room.unreadEmphasis {
        case .ordinary: accent.foreground(in: colorScheme)
        case .muted: AnyShapeStyle(.white)
        }
    }

    /// The "@" is always the accent, even in a silenced room: Matrix lets a mention through a
    /// muted room's own rule, and so does this.
    private var mentionFill: AnyShapeStyle {
        AnyShapeStyle(accent.color)
    }
}

/// A room somebody has asked you into, and the two answers.
///
/// It sits in the same list as the conversations and reads like a sibling of `RoomRow` — same
/// avatar, same name in the same weight — because it *is* one: the difference is not that it is a
/// different kind of thing, it is that it is asking rather than telling. So instead of a last
/// message it carries who invited you, and instead of being openable it carries the two buttons
/// that are the only things you can do with it.
///
/// The buttons carry a style of their own, which matters inside a `List`: a `Button` left to the
/// list's own styling gives its whole row the tap, so pressing anywhere would fire whichever
/// button SwiftUI picked.
private struct InviteRow: View {
    let room: RoomSummary
    let onAccept: () -> Void
    let onDecline: () -> Void

    @Environment(\.accent) private var accent
    @Environment(\.isOffline) private var isOffline

    var body: some View {
        HStack(spacing: Theme.Spacing.normal) {
            // A space wears a square-cornered face so it reads as a space, not a chat, before its
            // name is even read — see `AvatarShape`.
            // A space is a shelf of rooms rather than somebody to look at, so it gets no
            // creature — only the square and its initials.
            RoomAvatar(name: room.name, url: room.avatarURL, size: Theme.Size.roomAvatar,
                       shape: room.isSpace ? .roundedSquare : .circle,
                       seed: room.isSpace ? nil : room.avatarSeed,
                       faces: room.faces)

            VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                HStack(spacing: Theme.Spacing.tight) {
                    Text(room.name)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)

                    if room.privacy == .protected {
                        Image(systemName: "lock.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(Text(Strings.RoomList.privateChat))
                    }

                    Spacer(minLength: 0)
                }

                Text(invitation)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                // Green and red, and neither one nudged ahead of the other — see `AnswerStyle`.
                // The two used to be a filled "Join" beside a bordered "Decline", which is the
                // shape of a screen with one action and a way out of it. This is not that: both
                // are real answers, and the row was quietly nudging towards one of them while
                // making the other look like the smaller, safer thing to press.
                //
                // They used to be stretched to `maxWidth: .infinity` as well, each taking half
                // the row, which made them equal by making them enormous: two full-width slabs
                // under every invitation in a list of ordinary chat rows. They are the size of
                // their own words now, sitting together on the leading edge with the `Spacer`
                // taking the rest — small enough to read as a pair of answers to the sentence
                // above them rather than as a screen of their own. Equality is carried by the
                // style, which gives both the same font, padding and height, and not by width:
                // "Войти" is a shorter word than "Отклонить" and pretending otherwise is what
                // cost the row its proportions.
                HStack(spacing: Theme.Spacing.tight) {
                    Button(String(app: Strings.RoomList.Invite.accept), action: onAccept)
                        .buttonStyle(.answer(.accepting))

                    Button(String(app: Strings.RoomList.Invite.decline), action: onDecline)
                        .buttonStyle(.answer(.declining))

                    Spacer(minLength: 0)
                }
                .padding(.top, Theme.Spacing.tight)
                // Joining is `client.joinRoomById` and declining is `room.leave()` — both go straight
                // to the server, and neither is queued. The invitation keeps until the network is
                // back; a press that silently did nothing would not.
                .disabled(isOffline)
            }
        }
        .padding(.vertical, Theme.Spacing.tight)
        // Combined for the *label*, but the buttons stay reachable: VoiceOver reads the row as one
        // sentence and then offers "Join" and "Decline" as its actions, which is what a question
        // with two answers ought to sound like.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(invitation))
    }

    private var invitation: String {
        guard let person = room.invitedBy else {
            return String(app: Strings.RoomList.Invite.unattributed)
        }
        return String(app: Strings.RoomList.Invite.from(person))
    }
}

// `Avatar` used to live here, and it never loaded anything: it drew initials and dropped the
// URL on the floor, so there was not a single face anywhere in the app. It is now its own
// view in `Support/Avatar.swift`, and it fetches.

extension View {
    /// A separator between one row and the next, and nowhere else.
    ///
    /// A plain `List` also draws one *above* the first row and *below* the last, which is a
    /// hairline hanging under the toolbar and another floating beneath the final chat — lines
    /// that divide a conversation from nothing. Only the interior ones say anything, so the
    /// two outer edges are switched off at the ends of the list.
    ///
    /// The edges are hidden only on the rows that own them, rather than hiding `.top`
    /// everywhere and keeping `.bottom`: between two rows the two edges are the same line, and
    /// asking for it to be hidden from either side is enough to lose it.
    func separatorsBetweenRowsOnly(isFirst: Bool, isLast: Bool) -> some View {
        listRowSeparator(isFirst ? .hidden : .automatic, edges: .top)
            .listRowSeparator(isLast ? .hidden : .automatic, edges: .bottom)
    }
}
