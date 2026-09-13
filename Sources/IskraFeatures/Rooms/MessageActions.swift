import SwiftUI
import IskraCore
import IskraDesign

/// Everything you can *do* to a message, lifted off the shape it is drawn in.
///
/// A bubble and a compact line are two ways of showing the same message, and the long press
/// on them offers the same nine things either way: react, reply, edit, copy, forward, pin,
/// delete, report, block. None of that is a fact about the shape — so none of it lives with
/// the shape. It lives here, and both rows put it on.
///
/// The alternative was to leave it in `MessageRow` and copy it into the compact row, which is
/// the arrangement that guarantees the two menus drift: somebody adds an item to one of them,
/// nothing fails, and the app quietly offers different things depending on a setting.
///
/// It goes on the *content* — the bubble, the picture, the line — and not on the whole row.
/// That is deliberate: the long press lifts what it is attached to, and a menu attached to the
/// row would lift the avatar, the clock and the width of the screen along with the message.
/// The one gesture that does belong to the whole row is the swipe, which is why it is a
/// separate modifier — see `SwipeToReply`.
///
/// It is a view that *wraps* the content rather than a modifier applied to it, and that is not
/// a matter of taste. The menu lifts a copy of the message out of the scroll view and draws it
/// over the darkened room — so it needs the message as something it can build a second time,
/// in a different place. A `ViewModifier` is handed an opaque `Content` it may only place
/// where it stands; a closure can be called twice. See `MessageMenu`.
struct MessageActions<Content: View>: View {
    let message: Message

    /// Whether this message is currently pinned, which is the whole of what the menu item
    /// needs to know to say the right word.
    let isPinned: Bool

    let handlers: MessageHandlers

    @ViewBuilder let content: () -> Content

    /// Where the message is on screen, in the app-wide coordinate space the menu measures
    /// everything in — see `MessageMenu.space`. Kept up to date rather than read on the press,
    /// because by the time the press has happened there is no geometry left to ask.
    ///
    /// A box holding a rectangle, and not `@State` holding one, which is the difference between
    /// a conversation that scrolls and a conversation that crawls. This is measured on every
    /// message on screen, and the value changes on every frame of every scroll — as `@State`
    /// that is a body re-run per message per frame, each of which rebuilds a bubble in order to
    /// arrive at a number nothing on screen is drawn from. The box is a reference SwiftUI is not
    /// watching: written freely, read once, when a finger has actually been held down.
    @State private var anchor = Anchor()

    /// See `anchor`. A class, so that writing to it is not a change to this view.
    @MainActor
    private final class Anchor {
        var rect: CGRect = .zero
    }

    /// Whether a finger is currently down on the message, which the bubble answers by giving
    /// very slightly under it. The whole of the feedback that the press is being *counted* —
    /// without it the moment before the lift is a moment of nothing.
    ///
    /// `@GestureState` rather than `@State`, and that is not a style choice: gesture state resets
    /// itself the instant the gesture ends, *including* when it ends by failing. A press released
    /// early, or one that turns into a scroll, leaves nothing behind — where a plain flag would
    /// need a callback that does not fire on failure, and a bubble could be left sitting at 97%.
    @GestureState private var isPressing = false

    /// Guarding a redaction behind a confirmation, because it cannot be undone and every
    /// other item in that menu can.
    @State private var isConfirmingDelete = false

    /// Whether the report form is up for this message.
    @State private var isReporting = false

    /// Whether the "block this sender?" confirmation is up.
    @State private var isConfirmingBlock = false

    /// Whether the room picker for forwarding is up.
    @State private var isForwarding = false

    /// Counts double taps, and exists only to be a thing that *changes*: `sensoryFeedback`
    /// fires on a change of value, and "the user did it again" is otherwise not one.
    @State private var quickTaps = 0

    /// Offline, a message can be read, quoted and copied — and nothing else. Reacting, editing,
    /// deleting and pinning are all changes to what the *room* holds, and a room offline is a room
    /// nobody can be told about. Replying is the exception, and only looks like one: a reply is a new
    /// message, and a new message goes into the send queue and leaves when the network does.
    @Environment(\.isOffline) private var isOffline

    /// The account's block list, for blocking a message's sender from the menu.
    @Environment(\.blockStore) private var blockStore

    /// The forward capability, for sending this message into another room.
    @Environment(\.forwarding) private var forwarding

    /// The menu itself, which lives above the whole app — see `messageMenuLayer()`.
    @Environment(\.messageMenu) private var menu

    /// The emoji a double tap leaves. The user's, chosen once in settings and read by every
    /// row in every conversation — see `QuickReaction`.
    @AppStorage(QuickReaction.storageKey) private var quickReaction: QuickReaction = .default

    /// The press that opens the menu, and the double tap that does not wait for it.
    ///
    /// The menu is drawn by this app rather than by the system, and `MessageMenu` is where the
    /// reasons are — the short of it is that on iOS 27 a system context menu grows items nobody
    /// here put in it, one of which offers to send a message in an encrypted room somewhere
    /// else. What was bought back by going to `.contextMenu` the first time round — the lift,
    /// the dim, the system's own animation — is drawn here instead rather than given up.
    ///
    /// A quarter of a second, which is half the system's own wait and not a number the system can
    /// be talked down to. On a message you have already decided to answer, half a second reads as
    /// the app deliberating about whether to let you — see `Theme.Timing.menuLift`, which is where
    /// the number is and why it is that one, and `ScrollTouches`, without which the scroll view
    /// adds 150 ms in front of it.
    ///
    /// And a quarter of a second is what it now *is*, which is the third time this wait has been
    /// hunted and the first time the hunt ended where the time was actually going. The number was
    /// never the problem — it had been cut to a tenth by then — and a hold still took the better
    /// part of a second to lift a message. The delay was the double tap.
    ///
    /// The two gestures used to be separate: a `.highPriorityGesture` double tap over the content,
    /// and an `.onLongPressGesture` outside it. High priority means the tap is offered the touch
    /// first, so the press could not be recognised until the tap had *failed* — and a tap
    /// recogniser does not fail when a finger goes down and stays down. It fails on its own
    /// timeout, which is around three quarters of a second. That was the wait, and it was
    /// invisible because nothing in either gesture's own arithmetic mentions it.
    ///
    /// So they are one gesture now — see `press`.
    var body: some View {
        content()
            // The anchor. Measured continuously as the conversation scrolls, so the menu can
            // put its copy of the message exactly where the original is standing.
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .named(MessageMenu.space))
            } action: { anchor.rect = $0 }
            // The wait, made visible. The bubble sinks over exactly the length of the press and
            // arrives at the bottom as the menu takes over, so a held finger is watching something
            // happen instead of waiting for it — and a press abandoned halfway springs back, which
            // is how the app says "that wasn't long enough" without anything appearing to explain
            // it. See `Theme.Scale.pressedMessage` and `Theme.Timing.menuReleases`.
            .scaleEffect(isPressing ? Theme.Scale.pressedMessage : 1)
            .animation(isPressing ? .easeOut(duration: Theme.Timing.menuLift) : Theme.Timing.menuReleases,
                       value: isPressing)
            // The hold and the double tap, as one gesture — see `press`. The single tap still
            // lands underneath, so a photograph still opens and a round video still plays; the
            // cost is that a single tap on those waits out the double-tap interval, which is the
            // price of the quick reaction being true of every message rather than only of text.
            .highPriorityGesture(press)
            // The knock that says the reaction went. Without it a double tap on a message
            // whose pill appears a beat later feels like nothing happened.
            .sensoryFeedback(.impact(weight: .medium), trigger: quickTaps)
            // And on a Mac, the click a Mac user will try first. It is a separate gesture and
            // not a variant of the press because it is a different *act*: a right-click is
            // instant and has never had to be held.
            #if os(macOS)
            .overlay { RightClickCatcher(perform: open) }
            #endif
            .confirmationDialog(Text(Strings.Message.Menu.deleteConfirmTitle),
                                isPresented: $isConfirmingDelete,
                                titleVisibility: .visible) {
                Button(String(app: Strings.Message.Menu.delete), role: .destructive, action: handlers.onDelete)
            } message: {
                Text(Strings.Message.Menu.deleteConfirmMessage)
            }
            .sheet(isPresented: $isReporting) {
                ReportSheet(onReport: handlers.onReport)
            }
            .sheet(isPresented: $isForwarding) {
                if let forwarding {
                    ForwardPicker(message: message, forwarding: forwarding)
                }
            }
            .confirmationDialog(Text(Strings.Message.Menu.blockConfirm(message.senderName)),
                                isPresented: $isConfirmingBlock,
                                titleVisibility: .visible) {
                Button(String(app: Strings.Message.Menu.block), role: .destructive) {
                    let sender = message.senderID
                    Task { await blockStore?.block(userID: sender) }
                }
            } message: {
                Text(Strings.Message.Menu.blockConfirmMessage)
            }
    }

    /// Hands the message, and everything that can be done to it, to the menu above the app.
    ///
    /// The *content* goes with it — `content()` called a second time — so what lifts off the
    /// page is the real bubble rather than a picture of one: a video note goes on playing while
    /// the menu is open, and a photograph is still a photograph.
    /// The press that lifts the message, and — only if the press never happens — the double tap
    /// that leaves a reaction.
    ///
    /// One gesture rather than two, so the choice between them is a single arbitration instead of
    /// two recognisers waiting each other out; the note on `body` has the three quarters of a
    /// second that bought back. `exclusively(before:)` tries the press first and gives it the touch
    /// outright at `menuLift`; the double tap is offered the touch only once the press has failed,
    /// which is exactly what a finger lifted before `menuLift` has made it do. Nothing waits on a
    /// timeout, and the tap is unharmed: a tap is over in a fraction of the quarter second the
    /// press needs.
    ///
    /// At high priority over the content, which is what makes both acts true of *every* message
    /// rather than only the ones with nothing else to tap. A photograph opens the viewer on one
    /// tap, a location opens Maps, a video note plays — and those are exactly the messages people
    /// react to most. SwiftUI gives the innermost gesture first refusal, so without this the two
    /// things this file exists for would be unreachable on precisely those three. A single tap
    /// still lands underneath when neither of these claims the touch.
    private var press: some Gesture {
        LongPressGesture(minimumDuration: Theme.Timing.menuLift)
            // `updating` rather than a callback: true while the finger is down, and cleared by the
            // framework however the gesture ends. See `isPressing`.
            .updating($isPressing) { _, pressing, _ in pressing = true }
            .onEnded { _ in open() }
            .exclusively(before: TapGesture(count: 2).onEnded {
                // Offline the gesture is not merely refused, it is *silent* — and that is the whole
                // reason to guard it here as well as in the menu. A double tap that puts no pill on
                // the message reads as an app that did not notice the tap, so somebody would tap
                // again, harder, and go on tapping. See `isOffline`.
                guard message.canReact, !isOffline else { return }
                quickTaps += 1
                handlers.onToggleReaction(quickReaction.key)
            })
    }

    private func open() {
        let rect = anchor.rect
        guard let menu, rect != .zero else { return }
        menu.present(MessageMenuPresentation(
            id: message.id,
            anchor: rect,
            isOwn: message.isOwn,
            canReact: message.canReact && !isOffline,
            mine: Set(message.reactions.filter(\.isMine).map(\.key)),
            content: AnyView(content()),
            sections: sections,
            onReaction: handlers.onToggleReaction))
    }

    // MARK: - What the menu offers

    /// The verbs, in three groups: the things you do to a message, the things you do about
    /// one, and the two dates that are not things at all.
    ///
    /// A message that has been taken back keeps its menu, and that is a change from a version
    /// of this app that gave it none, on the grounds that every *action* in it was about
    /// content that is no longer there. That reasoning was sound and the conclusion was wrong.
    /// The menu is not only actions: the one thing a tombstone still knows is *when* — when it
    /// was sent, and when it went — and those are exactly the two questions somebody presses a
    /// deleted message to ask. So the actions go and the facts stay.
    ///
    /// Reactions are gone from it entirely, and not merely hidden. Matrix would accept an
    /// emoji on a redacted event quite happily, and the whole room would then be looking at a
    /// 👍 hanging under the words "message deleted" — see `Message.canReact`, which the store
    /// enforces as well.
    private var sections: [MessageMenuSection] {
        [MessageMenuSection(actions: doing),
         MessageMenuSection(actions: reporting),
         MessageMenuSection(actions: facts)]
            .filter { !$0.actions.isEmpty }
    }

    private var doing: [MessageMenuAction] {
        var actions: [MessageMenuAction] = []

        if message.canReply {
            actions.append(MessageMenuAction(title: Strings.Message.Menu.reply,
                                             systemImage: "arrowshape.turn.up.left",
                                             perform: handlers.onReply))
        }

        if message.canEdit && !isOffline {
            actions.append(MessageMenuAction(title: Strings.Message.Menu.edit,
                                             systemImage: "pencil",
                                             perform: handlers.onEdit))
        }

        if let text = copyableText {
            actions.append(MessageMenuAction(title: Strings.Message.Menu.copy,
                                             systemImage: "doc.on.doc",
                                             perform: { Clipboard.copy(text) }))
        }

        // Forwarding reaches another room, so it needs the network — offline there is nowhere for it
        // to go — and only the kinds a forward can faithfully rebuild are offered.
        if message.canForward, forwarding != nil, !isOffline {
            actions.append(MessageMenuAction(title: Strings.Message.Menu.forward,
                                             systemImage: "arrowshape.turn.up.right",
                                             perform: { isForwarding = true }))
        }

        // Pinning names an event, so it is offered on the same messages a reply is: one the
        // server actually has. The homeserver may still refuse it — pinning is a change to the
        // room's state and needs the power level for it — and that refusal is said in an alert
        // rather than predicted here, because a menu item that quietly disappears teaches the
        // user nothing about why.
        if message.canReply && !isOffline {
            actions.append(MessageMenuAction(title: isPinned ? Strings.Message.Menu.unpin : Strings.Message.Menu.pin,
                                             systemImage: isPinned ? "pin.slash" : "pin",
                                             perform: handlers.onTogglePin))
        }

        return actions
    }

    /// The red ones, kept together at the foot of the menu so that nothing irreversible sits
    /// next to something that is not.
    private var reporting: [MessageMenuAction] {
        var actions: [MessageMenuAction] = []

        if message.canDelete && !isOffline {
            actions.append(MessageMenuAction(title: Strings.Message.Menu.delete,
                                             systemImage: "trash",
                                             manner: .destructive,
                                             perform: { isConfirmingDelete = true }))
        }

        // Reporting is for somebody else's message — you do not flag your own — and only one the
        // server has, since a report points at an event ID. A deleted message has nothing left to
        // report. Offline there is no moderator to reach.
        if !message.isOwn && !message.isDeleted && !isOffline {
            actions.append(MessageMenuAction(title: Strings.Message.Menu.report,
                                             systemImage: "exclamationmark.bubble",
                                             manner: .destructive,
                                             perform: { isReporting = true }))
        }

        // Block the sender — someone else, and only when there is a block list to add them to.
        if !message.isOwn && blockStore != nil {
            actions.append(MessageMenuAction(title: Strings.Message.Menu.block,
                                             systemImage: "hand.raised",
                                             manner: .destructive,
                                             perform: { isConfirmingBlock = true }))
        }

        return actions
    }

    /// When it was sent, when somebody read it, and — if it is gone — when it went. The clock
    /// beside the bubble gives the hour and nothing else, which is all it has room for and all
    /// anybody needs until the day they need the rest; this is where the rest is.
    ///
    /// Its own section, so there is a rule above it and the facts do not read as two more
    /// things to press.
    private var facts: [MessageMenuAction] {
        var actions = [MessageMenuAction(title: Strings.Message.Menu.sentAt(Self.exactly(message.timestamp)),
                                         systemImage: "clock",
                                         manner: .fact)]

        // Only on your own, and only when a receipt actually carried a moment — see
        // `Message.readAt`. The ticks beside the bubble already say *that* it was read, and
        // this is the one thing they have no room to say: when.
        if let readAt = message.readAt {
            actions.append(MessageMenuAction(title: Strings.Message.Menu.readAt(Self.exactly(readAt)),
                                             systemImage: "checkmark.circle",
                                             manner: .fact))
        }

        if let deletedAt = message.deletedAt {
            actions.append(MessageMenuAction(title: Strings.Message.Menu.deletedAt(Self.exactly(deletedAt)),
                                             systemImage: "trash",
                                             manner: .fact))
        }

        return actions
    }

    /// The full moment, spelled out: "12 Jul 2026 at 14:03:07".
    ///
    /// `.abbreviated` rather than `.complete`, because the weekday in front of it is a word
    /// nobody was asking for. `.standard` rather than `.shortened`, because that is the one
    /// that carries the seconds — and this row exists precisely for the reader who wants more
    /// than the clock beside the bubble is willing to say. The order of the parts, and the
    /// word between them, are the locale's.
    private static func exactly(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .standard)
    }

    /// Only what the user could sensibly paste somewhere else. A photo has no text to
    /// copy, and a "Copy" that quietly puts a filename on the clipboard is worse than no
    /// "Copy" at all.
    private var copyableText: String? {
        switch message.kind {
        case let .text(body): body
        case let .notice(body): body
        case let .emote(body): body
        default: nil
        }
    }
}

#if os(macOS)
/// The right-click, which SwiftUI has no gesture for.
///
/// `.contextMenu` is the only thing in SwiftUI that answers to a secondary click, and a
/// secondary click is the whole way a Mac user opens a menu — so the one place this app still
/// has to reach into AppKit is here. It is a transparent view laid over the message that
/// refuses every event it is offered *except* a right-click: `hitTest` returning nil is what
/// lets a left click, a drag, a scroll and a double tap pass straight through to the message
/// underneath as though this were not here at all.
private struct RightClickCatcher: NSViewRepresentable {
    let perform: () -> Void

    func makeNSView(context: Context) -> Catcher {
        let view = Catcher()
        view.perform = perform
        return view
    }

    func updateNSView(_ view: Catcher, context: Context) {
        view.perform = perform
    }

    final class Catcher: NSView {
        var perform: () -> Void = {}

        override func hitTest(_ point: NSPoint) -> NSView? {
            switch NSApp.currentEvent?.type {
            case .rightMouseDown, .rightMouseUp, .rightMouseDragged: super.hitTest(point)
            default: nil
            }
        }

        override func rightMouseDown(with event: NSEvent) {
            perform()
        }
    }
}
#endif

/// Dragging a message toward the middle of the screen to answer it.
///
/// This one *does* go on the whole row rather than on the bubble, and that is the reason it is
/// not part of `MessageActions`: the thing that moves under the finger is the message and
/// everything that belongs to it — the face beside it, the clock — and a bubble sliding out
/// from under its own avatar would read as a bug.
///
/// `minimumDistance` keeps it out of the way of scrolling, and the row is inset from the screen
/// edge (avatar, margins) so the incoming-message swipe does not start where the system's
/// back-edge gesture lives — a thing to confirm on a device, where that gesture actually exists.
struct SwipeToReply: ViewModifier {
    let message: Message

    /// Which way the message gives when it is pulled.
    ///
    /// A message is dragged *toward the middle of the screen*, away from the side it is anchored
    /// to — so in the bubble layout your own message, sitting on the right, gives to the leading
    /// edge, and everybody else's gives to the trailing one. It is handed in rather than read off
    /// `isOwn`, because the compact layout anchors every message to the same side and there the
    /// answer is the same for all of them, your own included.
    let dragsToward: HorizontalEdge

    let onReply: () -> Void

    /// How far the row has been dragged toward the centre, and whether that drag has passed the
    /// point where letting go fires the reply. The offset springs back either way — the swipe is a
    /// shortcut that quotes the message, not a thing that flies off the screen.
    @State private var dragOffset: CGFloat = 0
    @State private var isArmed = false

    /// Bumped when the drag crosses the threshold, so the knock lands exactly once per swipe.
    @State private var haptic = 0

    /// The distance past which letting go replies.
    private static let threshold: CGFloat = 56

    func body(content: Content) -> some View {
        if message.canReply {
            content
                .offset(x: dragOffset)
                // The arrow waits on the edge the message is coming away from, which is the
                // opposite of the one it moves toward.
                .background(alignment: dragsToward == .leading ? .trailing : .leading) { hint }
                .gesture(gesture)
                .sensoryFeedback(.impact(weight: .light), trigger: haptic)
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: dragOffset)
        } else {
            content
        }
    }

    /// The arrow that fades in behind the message as it is dragged — the visual promise that
    /// letting go now will reply.
    private var hint: some View {
        Image(systemName: "arrowshape.turn.up.left.fill")
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, Theme.Spacing.normal)
            .opacity(min(1, Double(abs(dragOffset)) / Self.threshold))
            .scaleEffect(isArmed ? 1.1 : 0.9)
    }

    private var gesture: some Gesture {
        DragGesture(minimumDistance: 18)
            .onChanged { value in
                // Only a mostly-horizontal drag toward the centre. A drag that is more vertical
                // than horizontal belongs to the scroll view, and one heading for the edge is not
                // a reply.
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                let directed = dragsToward == .leading ? min(0, value.translation.width)
                                                       : max(0, value.translation.width)
                // Rubber-band: it gives, then resists, so it never flies to the edge.
                let capped = max(-Self.threshold * 1.6, min(Self.threshold * 1.6, directed))
                dragOffset = capped * 0.7

                let passed = abs(dragOffset) >= Self.threshold
                if passed != isArmed {
                    isArmed = passed
                    if passed { haptic += 1 }
                }
            }
            .onEnded { _ in
                if isArmed { onReply() }
                isArmed = false
                dragOffset = 0
            }
    }
}

extension View {
    /// Hangs everything a message can be asked to do off the shape it is drawn in — see
    /// `MessageActions`. Goes on the content, not the row.
    ///
    /// Still spelled as a modifier at the call site, even though what it builds is a view that
    /// wraps this one: a bubble should read as a bubble with a menu on it, and the two rows that
    /// use it should not have to care which of the two SwiftUI spellings is underneath.
    func messageActions(_ message: Message,
                        isPinned: Bool,
                        handlers: MessageHandlers) -> some View {
        MessageActions(message: message, isPinned: isPinned, handlers: handlers) { self }
    }

    /// Lets the row be dragged toward the middle of the screen to answer it — see `SwipeToReply`.
    /// Goes on the whole row, not the content.
    func swipeToReply(_ message: Message,
                      dragsToward: HorizontalEdge,
                      onReply: @escaping () -> Void) -> some View {
        modifier(SwipeToReply(message: message, dragsToward: dragsToward, onReply: onReply))
    }
}
