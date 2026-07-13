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

    /// Sign-out unwinds the whole app, not just this screen, so the decision belongs to
    /// whoever owns the session — here it is only reported.
    var onSignOut: () -> Void

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

    public init(session: UserSession,
                selectedRoomID: Binding<String?>,
                isSidebar: Bool,
                onSignOut: @escaping () -> Void) {
        self.session = session
        _selectedRoomID = selectedRoomID
        self.isSidebar = isSidebar
        self.onSignOut = onSignOut
    }

    public var body: some View {
        List(selection: $selectedRoomID) {
            if isSearching {
                searchResults
            } else {
                rooms
            }
        }
        .listStyle(.plain)
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
        .overlay { emptyState }
        // A real destination on this column's stack, not a view swapped in behind a
        // hand-rolled transition. That is what buys the stock push, the back button and
        // the swipe back — none of which is worth reimplementing, and all of which is
        // noticeably wrong when you do.
        .navigationDestination(isPresented: $isShowingSettings) {
            // In a sidebar the system pushes without giving the pushed screen a way back,
            // so settings has to draw its own. On iPhone it must not — there is already
            // one in the corner.
            SettingsView(session: session, onSignOut: onSignOut, showsBackButton: isSidebar)
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
    ///
    /// The two items are the shape of a feature that does not exist yet: nothing in
    /// `IskraCore` wraps the SDK's `createRoom`, and a half-built flow that cannot
    /// finish would be worse than a menu that plainly does nothing. The actions are
    /// empty on purpose, and this is the one place to wire them up when creation lands.
    private var newConversationMenu: some View {
        Menu {
            Button {
                // TODO: create a direct chat once IskraCore can.
            } label: {
                Label(Strings.RoomList.newChat, systemImage: "person")
            }

            Button {
                // TODO: create a room once IskraCore can.
            } label: {
                Label(Strings.RoomList.newRoom, systemImage: "person.3")
            }
        } label: {
            Image(systemName: "plus")
                .font(.body.weight(.medium))
        }
        .menuIndicator(.hidden)
        .accessibilityLabel(Text(Strings.RoomList.newConversation))
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
            RoomRow(room: room)
                .tag(room.id)
                .separatorsBetweenRowsOnly(isFirst: index == 0, isLast: index == rooms.count - 1)
        }
    }

    @ViewBuilder
    private var searchResults: some View {
        let hits = session.search.hits
        ForEach(Array(hits.enumerated()), id: \.element.id) { index, hit in
            Button {
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

/// One conversation in the list.
private struct RoomRow: View {
    let room: RoomSummary

    var body: some View {
        HStack(spacing: Theme.Spacing.normal) {
            Avatar(name: room.name, url: room.avatarURL, size: Theme.Size.avatar)

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

                    if let date = room.lastActivity {
                        Text(date, format: .relative(presentation: .numeric, unitsStyle: .narrow))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: Theme.Spacing.close) {
                    Text(room.lastMessage ?? " ")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

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
        .padding(.vertical, Theme.Spacing.tight)
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
        if let message = room.lastMessage { parts.append(message) }
        if room.isMentioned {
            parts.append(String(app: Strings.RoomList.mentions(room.mentionCount)))
        } else if room.hasUnread {
            parts.append(String(app: Strings.RoomList.unread(room.unreadCount)))
        }
        return parts.joined(separator: ", ")
    }
}

// `Avatar` used to live here, and it never loaded anything: it drew initials and dropped the
// URL on the floor, so there was not a single face anywhere in the app. It is now its own
// view in `Support/Avatar.swift`, and it fetches.
