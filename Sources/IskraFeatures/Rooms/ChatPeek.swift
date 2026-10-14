import SwiftUI
import IskraCore
import IskraDesign

/// A look inside a chat from the chat list, without going into it — and so without telling
/// anybody it was read.
///
/// A long press on a row lifts the conversation out over a darkened list: the latest messages,
/// scrollable back into history, and a short menu under them. Nothing about looking sends a
/// receipt. The room screen is the only thing in the app that calls `markAsRead()`, and this is
/// not the room screen — it is a separate timeline over the same room (see
/// `UserSession.peekTimeline(forRoomID:)`), opened for as long as the card is up and stopped when
/// it goes. "Open chat" is the way through, and *that* reads the room, the way a tap on the row
/// always has.
///
/// **Ours rather than the system's `.contextMenu(menuItems:preview:)`**, which was the obvious
/// first reach and cannot do the one thing asked of it: a context-menu preview is a picture
/// behind glass. It takes no touches, so it cannot scroll, and a peek that shows only the last
/// screenful of a conversation is a peek at whatever happened to be said last. The message menu
/// left the system's menu for reasons of its own — see `MessageMenu` — and this borrows its
/// pieces: the same curtain, the same rows of verbs, the same glass under them.
///
/// It sits above the whole app, like the message menu and for the same reason — see
/// `chatPeekLayer()`. On a phone the chat list is under a navigation bar, and a card drawn inside
/// the list would stop at it.
struct ChatPeekPresentation: Identifiable {
    let room: RoomSummary

    /// The peek's own store, started by the card and stopped with it. Never the one the room
    /// screen holds — see `UserSession.peekTimeline(forRoomID:)`.
    let timeline: TimelineStore

    /// What can be done from here, under the card. "Open chat" first.
    let actions: [MessageMenuAction]

    /// Going into the room for real — a tap on the card's header, the same as "Open chat".
    let onOpen: () -> Void

    var id: String { room.id }
}

@MainActor
@Observable
final class ChatPeekPresenter {
    private(set) var presentation: ChatPeekPresentation?

    /// Bumped on every opening, so the knock can be tied to a change — see `MessageMenuPresenter.lifts`.
    private(set) var lifts = 0

    func present(_ presentation: ChatPeekPresentation) {
        guard self.presentation?.id != presentation.id else { return }
        lifts += 1
        withAnimation(Theme.Timing.menuOpens) { self.presentation = presentation }
    }

    func dismiss() {
        guard presentation != nil else { return }
        withAnimation(.smooth(duration: Theme.Timing.chrome)) { presentation = nil }
    }

    /// Whether a tap on this room's row is really the finger that lifted it, coming back up.
    ///
    /// The hold does not consume the touch — it cannot, or the list would stop scrolling; see
    /// `MessageHold` — so when the finger leaves the glass the row underneath receives an ordinary
    /// tap and opens the chat. Which is precisely the thing the peek exists to avoid: opening the
    /// room reads it. While the card is up the curtain covers every row, so a tap arriving at the
    /// very row being peeked can only be that finger, and it is refused.
    func isPeeking(at roomID: String) -> Bool {
        presentation?.id == roomID
    }
}

extension EnvironmentValues {
    /// The peek, installed once at the root. Optional so that a list drawn anywhere else — a
    /// preview, a test — simply has no long press, rather than a crash.
    @Entry var chatPeek: ChatPeekPresenter?
}

extension View {
    /// Installs the chat peek above the whole app. Goes on at the root, beside
    /// `messageMenuLayer()`, and *before* the environment the root hands down, so that the
    /// messages in the card get the media loader and the rest — see the note there.
    func chatPeekLayer() -> some View {
        modifier(ChatPeekLayer())
    }
}

private struct ChatPeekLayer: ViewModifier {
    @State private var presenter = ChatPeekPresenter()

    func body(content: Content) -> some View {
        content
            .environment(\.chatPeek, presenter)
            .overlay { ChatPeekOverlay(presenter: presenter) }
    }
}

// MARK: - The row

extension View {
    /// Makes a chat row peekable: held on iPhone and iPad, right-clicked on a Mac. `onOpen` is
    /// what "Open chat" does — the same thing a tap on the row does.
    func chatPeek(_ room: RoomSummary, session: UserSession, onOpen: @escaping () -> Void) -> some View {
        modifier(ChatPeekTrigger(room: room, session: session, onOpen: onOpen))
    }
}

private struct ChatPeekTrigger: ViewModifier {
    let room: RoomSummary
    let session: UserSession
    let onOpen: () -> Void

    @Environment(\.chatPeek) private var peek

    func body(content: Content) -> some View {
        content
            // UIKit's hold on the phone, for the reason the message bubble uses it: a SwiftUI long
            // press inside a scrolling list takes the touch, and the list stops scrolling. See
            // `MessageHold`, which has the measurements.
            #if os(iOS)
            .overlay {
                MessageHold(duration: Theme.Timing.peekLift,
                            onPressingChanged: { _ in },
                            onHold: lift)
            }
            #else
            // A Mac has no long press worth the name, and a right-click is where a Mac user looks
            // for everything a row can do.
            .contextMenu {
                Button(action: lift) {
                    Label(String(app: Strings.RoomList.Peek.peek), systemImage: "eye")
                }
            }
            #endif
            // And for VoiceOver, where a hold is not a gesture anybody can find.
            .accessibilityAction(named: Text(Strings.RoomList.Peek.peek), lift)
    }

    private func lift() {
        guard let peek, let timeline = session.peekTimeline(forRoomID: room.id) else { return }
        peek.present(ChatPeekPresentation(room: room,
                                          timeline: timeline,
                                          actions: actions,
                                          onOpen: onOpen))
    }

    /// The row's own swipe actions, as words — see `RoomListSwipeActions` — with "Open chat" in
    /// front and leaving left out: leaving asks first, and a confirmation raised from under a card
    /// that has just been put away is a question with nothing left on screen to ask it about.
    private var actions: [MessageMenuAction] {
        let roomList = session.roomList
        let roomID = room.id

        return [
            MessageMenuAction(title: Strings.RoomList.Peek.open,
                              systemImage: "arrow.up.forward.app",
                              perform: onOpen),
            room.hasUnread
                ? MessageMenuAction(title: Strings.RoomList.Peek.markRead,
                                    systemImage: "envelope.open",
                                    perform: { Task { await roomList.markRead(roomID: roomID) } })
                : MessageMenuAction(title: Strings.RoomList.Peek.markUnread,
                                    systemImage: "envelope.badge",
                                    perform: { Task { await roomList.markUnread(roomID: roomID) } }),
            MessageMenuAction(title: room.isPinned ? Strings.RoomList.Swipe.unpin : Strings.RoomList.Swipe.pin,
                              systemImage: room.isPinned ? "pin.slash" : "pin",
                              perform: { [isPinned = room.isPinned] in
                                  Task { await roomList.setPinned(roomID: roomID, !isPinned) }
                              }),
            MessageMenuAction(title: room.isArchived ? Strings.RoomList.Swipe.unarchive : Strings.RoomList.Swipe.archive,
                              systemImage: room.isArchived ? "tray.and.arrow.up" : "archivebox",
                              perform: { [isArchived = room.isArchived] in
                                  Task { await roomList.setArchived(roomID: roomID, !isArchived) }
                              }),
        ]
    }
}

// MARK: - The overlay

private struct ChatPeekOverlay: View {
    let presenter: ChatPeekPresenter

    var body: some View {
        ZStack {
            if let presentation = presenter.presentation {
                MenuCurtain()
                    .ignoresSafeArea()
                    .contentShape(.rect)
                    .onTapGesture { presenter.dismiss() }
                    .accessibilityLabel(Text(Strings.RoomList.Peek.close))
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { presenter.dismiss() }
                    .transition(.opacity)

                column(presentation)
                    .transition(.scale(scale: 0.92).combined(with: .opacity))
            }
        }
        // Deaf when empty, for the reason `MessageMenuOverlay` gives: an empty layer over the whole
        // app is exactly what eats a tap six months from now.
        .allowsHitTesting(presenter.presentation != nil)
        .sensoryFeedback(.impact(weight: .medium), trigger: presenter.lifts)
    }

    private func column(_ presentation: ChatPeekPresentation) -> some View {
        VStack(alignment: .leading, spacing: MessageMenu.gap) {
            ChatPeekCard(presentation: presentation, onOpen: { open(presentation) })
                // A fresh card for every room: the store is started by the card and stopped when
                // it goes, and a card reused for the next room would be holding the last one's.
                .id(presentation.id)
                .frame(maxWidth: Theme.Size.peekWidth, maxHeight: Theme.Size.peekHeight)

            actions(presentation)
        }
        .padding(MessageMenu.margin)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #if os(macOS)
        .onExitCommand { presenter.dismiss() }
        #endif
        // VoiceOver stays inside while it is open — see the same line in `MessageMenuOverlay`.
        .accessibilityAddTraits(.isModal)
    }

    private func actions(_ presentation: ChatPeekPresentation) -> some View {
        VStack(spacing: 0) {
            ForEach(presentation.actions) { action in
                MessageMenuRow(action: action) {
                    presenter.dismiss()
                    action.perform()
                }
            }
        }
        .padding(.vertical, MessageMenuOverlay.listPadding)
        .padding(.horizontal, MessageMenuOverlay.listInset)
        .frame(width: Theme.Size.menuWidth)
        .clipShape(MessageMenuOverlay.panel)
        .navigationGlass(in: MessageMenuOverlay.panel)
    }

    private func open(_ presentation: ChatPeekPresentation) {
        presenter.dismiss()
        presentation.onOpen()
    }
}

// MARK: - The card

/// The conversation, read-only, in its own scroll view.
///
/// The same rows the room draws, in the same layout the reader chose — a peek in bubbles at a
/// chat that opens as a plain column would be a preview of a different screen. What the rows are
/// *not* given is anything to do: no handlers, and no message menu, so a press on a bubble in
/// here lifts nothing. Acting on a message is what going into the chat is for.
private struct ChatPeekCard: View {
    let presentation: ChatPeekPresentation
    let onOpen: () -> Void

    @AppStorage(MessageLayout.storageKey) private var messageLayout: MessageLayout = .default

    /// See `EnvironmentValues.timelineWidth` — measured on the container, never in a row.
    @State private var timelineWidth: CGFloat = 0

    /// Whether the reader has touched the scroll yet. History is asked for from the top of the
    /// card, and until the card has been anchored at the bottom it *is* at the top — the same trap
    /// `RoomView` describes, where a room wound itself back to its first day unasked.
    @State private var hasScrolled = false

    private var timeline: TimelineStore { presentation.timeline }
    private var room: RoomSummary { presentation.room }

    var body: some View {
        VStack(spacing: 0) {
            header
            conversation
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.menu, style: .continuous))
        .shadow(color: .black.opacity(Theme.Backdrop.wash), radius: Theme.Spacing.normal, y: Theme.Spacing.tight)
        .task { try? await timeline.start() }
        .onDisappear { timeline.stop() }
    }

    /// Who this is, and the way in. A button because "tap the thing to open it" is what anybody
    /// tries first; "Open chat" below says the same for anybody who does not.
    private var header: some View {
        Button(action: onOpen) {
            HStack(spacing: Theme.Spacing.normal) {
                RoomAvatar(name: room.name, url: room.avatarURL, size: Theme.Size.avatarToolbar,
                           seed: room.avatarSeed, faces: room.faces)

                VStack(alignment: .leading, spacing: 0) {
                    Text(room.name)
                        .font(.headline)
                        .lineLimit(1)

                    // Only where it is news. In a chat with nothing unread there is nothing to
                    // leave unread, and the line would be a reassurance about nothing.
                    if room.hasUnread {
                        Text(Strings.RoomList.Peek.staysUnread)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Spacing.roomy)
            .padding(.vertical, Theme.Spacing.normal)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .background(.bar)
        .accessibilityHint(Text(Strings.RoomList.Peek.open))
    }

    private var conversation: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(placedRows) { placed in
                    view(for: placed)
                        .id(placed.id)
                }
            }
            .padding(.horizontal, Theme.Spacing.normal)
            .padding(.bottom, Theme.Spacing.close)
        }
        // At the latest message, and held there while history lands above — see the two lines
        // in `RoomView` these are copied from, which say why both are needed.
        .defaultScrollAnchor(.bottom)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .onScrollPhaseChange { _, phase in
            if phase == .interacting { hasScrolled = true }
        }
        // Older messages when the reader nears the top — which is what makes this a look at the
        // conversation and not at its last screenful. `loadMore` ignores a call while a page is
        // already coming and once the room has none left, so asking on every change is free.
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top
        } action: { _, offset in
            guard hasScrolled, offset < Self.historyMargin else { return }
            Task { await timeline.loadMore() }
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width - Theme.Spacing.normal * 2
        } action: { width in
            timelineWidth = width
        }
        .environment(\.timelineWidth, timelineWidth)
        // No menu for the messages in here. `MessageActions` asks for one on a long press and
        // quietly does nothing when there is none — see `open()` there.
        .environment(\.messageMenu, nil)
        .overlay { placeholder }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .chatWallpaper()
        // The page itself, under the wallpaper. Without a wallpaper `chatWallpaper` draws nothing,
        // and the card's conversation was see-through: the bubbles floated on the darkened chat
        // list behind it, under a header that did have a background of its own.
        .background(Color.page)
    }

    /// How near the top, in points, before the next page is asked for. A screen's worth, so the
    /// page has usually landed before the reader gets there.
    private static let historyMargin: CGFloat = 600

    @ViewBuilder
    private var placeholder: some View {
        if timeline.didFailToLoad {
            ContentUnavailableView(String(app: Strings.Room.loadFailedTitle),
                                   systemImage: "exclamationmark.bubble",
                                   description: Text(Strings.Room.loadFailedMessage))
        } else if !timeline.hasLoaded {
            ProgressView()
        } else if timeline.rows.isEmpty {
            ContentUnavailableView(String(app: Strings.Room.emptyTitle),
                                   systemImage: "bubble.left.and.bubble.right")
        }
    }

    // MARK: - Rows

    /// A row and what it needs to know about the one above it — see `RoomView.PlacedRow`, which
    /// this is the read-only twin of.
    private struct PlacedRow: Identifiable {
        let row: TimelineRow
        let followsEvent: Bool
        let opensDay: Bool
        let id: String
    }

    private var placedRows: [PlacedRow] {
        var previousWasEvent = false
        var previousWasDivider = false
        return timeline.rows.map { row in
            let placed = PlacedRow(row: row,
                                   followsEvent: previousWasEvent,
                                   opensDay: previousWasDivider,
                                   id: timeline.viewIdentity(of: row))
            if case .event = row { previousWasEvent = true } else { previousWasEvent = false }
            previousWasDivider = row.isDivider
            return placed
        }
    }

    /// Nothing arrives animated. A message landing while somebody peeks is still news, but the
    /// arrival is timed against a conversation the room screen has settled, and this one has not.
    @ViewBuilder
    private func view(for placed: PlacedRow) -> some View {
        switch placed.row {
        case let .dayDivider(divider):
            DayDividerView(date: divider.date)
        case .unreadDivider:
            UnreadDividerView()
        case let .event(event):
            RoomEventRow(event: event, followsEvent: placed.followsEvent, opensDay: placed.opensDay)
        case let .message(message):
            switch messageLayout {
            case .bubbles:
                MessageRow(message: message,
                           isOneToOne: timeline.isOneToOne,
                           opensDay: placed.opensDay,
                           arrivesAnimated: false)
            case .compact:
                CompactMessageRow(message: message,
                                  opensDay: placed.opensDay,
                                  arrivesAnimated: false)
            }
        }
    }
}

// MARK: - The curtain

/// What the app darkens behind something lifted out of it — the message menu, and the peek.
struct MenuCurtain: View {
    var body: some View {
        #if os(macOS)
        Rectangle()
            .fill(Color.black.opacity(Theme.Backdrop.menuScrim))
        #else
        Rectangle()
            .fill(.ultraThinMaterial)
            .overlay(Color.black.opacity(Theme.Backdrop.menuScrim))
        #endif
    }
}
