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

    @State private var searchText = ""
    @State private var isShowingSettings = false
    @State private var isShowingArchive = false

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

    /// The recovery flow, when the banner has been tapped. The banner has one reason to exist now —
    /// the history is locked — so there is nothing to carry into the flow but the fact of the tap.
    @State private var isFixingRecovery = false

    /// Which of the two things the "+" was pressed for, and nil when it was not.
    @State private var creating: NewConversationView.Kind?

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
        List(selection: $selectedRoomID) {
            if isSearching {
                searchResults
            } else {
                archiveEntry
                rooms
            }
        }
        .listStyle(.plain)
        // An invitation that would not be accepted or declined. The same apology every other
        // refusal in the app gets — see `FailureAlert`.
        .failureAlert(Bindable(session.roomList).failure)
        .navigationTitle(Text(Strings.RoomList.title))
        // A small title, centred, in the bar itself — not the large scrolling headline
        // SwiftUI would otherwise give this screen. `toolbarTitleDisplayMode` says that
        // on iOS and on the Mac; `navigationBarTitleDisplayMode` would only say it on iOS.
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            if isSidebar {
                ToolbarItem(placement: .primaryAction) { newConversationMenu }
                ToolbarItem(placement: .primaryAction) { settingsButton }
            } else {
                ToolbarItem(placement: .navigation) { newConversationMenu }
                // Its own glass, not the bar's — see `accountButton`.
                ToolbarItem(placement: .primaryAction) { accountButton }
                    .sharedBackgroundVisibility(.hidden)
            }
        }
        // Nothing to remove on iPhone — a collapsed split view never shows the toggle —
        // so this only bites where it is meant to, on iPad and Mac.
        .toolbar(removing: .sidebarToggle)
        // An inset rather than an overlay: this reserves the space, so the last
        // conversation can still be scrolled clear of the search field instead of
        // living underneath it forever.
        .safeAreaInset(edge: .bottom) {
            RoomSearchField(text: $searchText)
        }
        // And the same reasoning at the other end. The banner is in the way *on purpose* — it is
        // about messages the user cannot read, or a code that is one lost phone away from mattering
        // very much — but being in the way is not the same as sitting on top of the first
        // conversation, which is what an overlay would have done.
        .safeAreaInset(edge: .top) {
            RecoveryBanner(recovery: session.recovery) {
                isFixingRecovery = true
            }
        }
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
        // inset for exactly the reason the search field is one.
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
            ArchiveView(session: session) { roomID in
                // Opening a chat from the archive drops back to the main column and selects it —
                // the detail follows the selection, and the archive is a place you came from, not
                // one you stay in to read.
                selectedRoomID = roomID
                isShowingArchive = false
            }
        }
        .navigationDestination(isPresented: $isShowingSettings) {
            // In a sidebar the system pushes without giving the pushed screen a way back,
            // so settings has to draw its own. On iPhone it must not — there is already
            // one in the corner.
            SettingsView(session: session,
                         onSignOut: onSignOut,
                         onClearedCache: onClearedCache,
                         showsBackButton: isSidebar)
        }
        // A sheet, not a push: creating a chat is a question with a Cancel, and the answer
        // to it replaces what is *behind* this column — so it is a thing you put down, not
        // a place you go back from.
        .sheet(item: $creating) { kind in
            NewConversationView(kind: kind, session: session) { roomID in
                // Openable already: `createRoom` does not come back until the SDK has the
                // room, so selecting it here does not race the sync that will put it in
                // the list a moment later. See `UserSession.timeline(forRoomID:)`.
                selectedRoomID = roomID
            }
        }
        .onChange(of: searchText) { _, query in
            session.search.search(query)
        }
    }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: - Chrome

    /// The "+": top-left on iPhone, beside the gear on iPad and Mac.
    private var newConversationMenu: some View {
        Menu {
            Button {
                creating = .directChat
            } label: {
                Label(Strings.RoomList.newChat, systemImage: "person")
            }

            Button {
                creating = .room
            } label: {
                Label(Strings.RoomList.newRoom, systemImage: "person.3")
            }
        } label: {
            Image(systemName: "plus")
                .font(.body.weight(.medium))
        }
        .menuIndicator(.hidden)
        .accessibilityLabel(Text(Strings.RoomList.newConversation))
        // Making a room is a conversation with the server, and offline there is nobody to have it
        // with: `client.createRoom` is a plain network call with no queue behind it. Left enabled, it
        // would take somebody through the whole New Chat screen — a name, a topic, a person to invite
        // — and refuse at the last press. The button that cannot work says so before it is pressed.
        .disabled(isOffline)
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
                   size: Theme.Size.avatarToolbar)
                .padding(Theme.Spacing.tight)
                .navigationGlass(in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(Strings.Account.settings))
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
    }

    // MARK: - Content

    @ViewBuilder
    private var rooms: some View {
        let rooms = session.roomList.rooms
        ForEach(Array(rooms.enumerated()), id: \.element.id) { index, room in
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
                        RoomRow(room: room)
                    }
                    .buttonStyle(.plain)
                    .roomListSwipeActions(room: room,
                                          roomList: session.roomList,
                                          onLeave: { roomToLeave = room })
                } else {
                    RoomRow(room: room)
                        .tag(room.id)
                        .roomListSwipeActions(room: room,
                                              roomList: session.roomList,
                                              onLeave: { roomToLeave = room })
                }
            }
            .separatorsBetweenRowsOnly(isFirst: index == 0, isLast: index == rooms.count - 1)
        }
    }

    /// The way into the archive, shown only when there is something in it. A quiet row at the top of
    /// the list — the same place Telegram keeps it — rather than a permanent piece of chrome for a
    /// shelf that is usually empty.
    @ViewBuilder
    private var archiveEntry: some View {
        let archived = session.roomList.archivedRooms
        if !archived.isEmpty {
            Button {
                isShowingArchive = true
            } label: {
                Label(String(app: Strings.RoomList.Archive.entry(archived.count)),
                      systemImage: "archivebox")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
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
                ProgressView { Text(Strings.RoomList.loading) }
            } else {
                ContentUnavailableView(String(app: Strings.RoomList.emptyTitle),
                                       systemImage: "bubble.left.and.bubble.right",
                                       description: Text(Strings.RoomList.emptyMessage))
            }
        }
    }
}

private extension View {
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

/// One conversation in the list. Internal, not private, so the archive screen renders its rows the
/// same way the main list does — an archived chat should look like exactly what it is.
struct RoomRow: View {
    let room: RoomSummary

    var body: some View {
        HStack(spacing: Theme.Spacing.normal) {
            // A space wears a square-cornered face so it reads as a space, not a chat, before its
            // name is even read — see `AvatarShape`.
            Avatar(name: room.name, url: room.avatarURL, size: Theme.Size.roomAvatar,
                   shape: room.isSpace ? .roundedSquare : .circle)

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

                    // Pinned chats wear a small pin beside the name, the same shape the swipe
                    // action uses — so the row says "stays at the top" without needing words.
                    if room.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(Text(Strings.RoomList.pinned))
                    }

                    Spacer(minLength: 0)

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
                    Text(room.lastMessage ?? " ")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        // Two lines, and the space for both is kept even when only one is used.
                        //
                        // Without `reservesSpace` a list of chats has rows of two different
                        // heights, depending on how long each last message happens to be — and the
                        // eye reads that ragged column as the list being *sorted* by something,
                        // which it is not. A steady row is what lets the faces beside them scan as
                        // a column at all.
                        .lineLimit(2, reservesSpace: true)

                    Spacer(minLength: 0)

                    if room.hasUnread {
                        // A count, not a sentence — but still formatted for the locale
                        // rather than interpolated, so the digits are the right ones.
                        //
                        // Two badges, and only one of them is a colour. A mention is red —
                        // it is the one badge that means "you, specifically", and it is red
                        // whatever the app is painted in, with white on it. An ordinary
                        // unread count used to be the accent, which made a list of chats the
                        // loudest screen in the app and left red with nothing to stand out
                        // against; it is grey now, and the red is legible again.
                        Text(room.unreadCount, format: .number)
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .foregroundStyle(room.isMentioned ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(room.isMentioned ? AnyShapeStyle(Color.red)
                                                         : AnyShapeStyle(Color.primary.opacity(0.16)),
                                        in: Capsule())
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
        if room.hasUnread {
            parts.append(String(app: Strings.RoomList.unread(room.unreadCount)))
        }
        if room.isMentioned {
            parts.append(String(app: Strings.RoomList.mentions(room.mentionCount)))
        }
        return parts.joined(separator: ", ")
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
/// The buttons are `.borderless`, which matters inside a `List`: a plain `Button` in a list row
/// gives its whole row the tap, so pressing anywhere would fire whichever button SwiftUI picked.
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
            Avatar(name: room.name, url: room.avatarURL, size: Theme.Size.roomAvatar,
                   shape: room.isSpace ? .roundedSquare : .circle)

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

                HStack(spacing: Theme.Spacing.close) {
                    Button(String(app: Strings.RoomList.Invite.accept), action: onAccept)
                        .buttonStyle(.primaryAction)

                    Button(String(app: Strings.RoomList.Invite.decline), action: onDecline)
                        .buttonStyle(.bordered)

                    Spacer(minLength: 0)
                }
                .controlSize(.small)
                .buttonBorderShape(.capsule)
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
