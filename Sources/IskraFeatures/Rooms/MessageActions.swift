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
struct MessageActions: ViewModifier {
    let message: Message

    /// Whether this message is currently pinned, which is the whole of what the menu item
    /// needs to know to say the right word.
    let isPinned: Bool

    let handlers: MessageHandlers

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

    /// The emoji a double tap leaves. The user's, chosen once in settings and read by every
    /// row in every conversation — see `QuickReaction`.
    @AppStorage(QuickReaction.storageKey) private var quickReaction: QuickReaction = .default

    /// The system's own context menu, on both platforms: the right-click a Mac user expects,
    /// and on the phone the long press that lifts the bubble off a conversation the system
    /// darkens behind it.
    ///
    /// This was hand-drawn once — a quarter-second press of our own opening a popover —
    /// because `.contextMenu` waits about half a second and the system will not shorten it,
    /// and on a message you have already decided to react to that wait is the app thinking
    /// about whether to let you. What the popover cost was everything around it: no lift, no
    /// dim, none of the system's animation, and a menu that was ours to keep in step with a
    /// platform that moves. The wait is answered instead by the double tap below, which is
    /// instant and sends the reaction that was usually the reason for opening the menu at
    /// all — so the menu is free to be the real one.
    func body(content: Content) -> some View {
        content
            // A double tap is the quick reaction, and `highPriorityGesture` is what makes that
            // true of *every* message rather than only the ones with nothing else to tap.
            //
            // It used to be a plain `.onTapGesture(count: 2)`, on the reasoning that nothing else
            // in a conversation answers to two taps. Several things do, and they are the ones
            // people react to most: a photograph opens the viewer on one tap, a location opens
            // Maps, a video note plays. SwiftUI gives the *innermost* gesture first refusal, so on
            // exactly those three the quick reaction was unreachable — while the settings screen
            // went on saying "double-tap a message to leave it". The promise was true of text and
            // of nothing else.
            //
            // At high priority the double tap is offered first and the single tap still lands when
            // it fails, so the photo still opens and the circle still plays. The cost is that a
            // single tap on those waits out the double-tap interval, which is the price of the
            // promise being kept.
            .highPriorityGesture(TapGesture(count: 2).onEnded {
                // Offline the gesture is not merely refused, it is *silent* — and that is the whole
                // reason to guard it here as well as in the menu. A double tap that puts no pill on
                // the message reads as an app that did not notice the tap, so somebody would tap
                // again, harder, and go on tapping. See `isOffline`.
                guard message.canReact, !isOffline else { return }
                quickTaps += 1
                handlers.onToggleReaction(quickReaction.key)
            })
            // The knock that says the reaction went. Without it a double tap on a message
            // whose pill appears a beat later feels like nothing happened.
            .sensoryFeedback(.impact(weight: .medium), trigger: quickTaps)
            .contextMenu { menu }
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

    /// What a long press — or a right-click — offers.
    ///
    /// A message that has been taken back keeps its menu, and that is a change: it used to
    /// have none, on the grounds that every *action* in it was about content that is no
    /// longer there. That reasoning was sound and the conclusion was wrong. The menu is not
    /// only actions: the one thing a tombstone still knows is *when* — when it was sent, and
    /// when it went — and those are exactly the two questions somebody presses a deleted
    /// message to ask. So the actions go and the facts stay.
    ///
    /// Reactions are gone from it entirely, and not merely hidden. Matrix would accept an
    /// emoji on a redacted event quite happily, and the whole room would then be looking at a
    /// 👍 hanging under the words "message deleted" — see `Message.canReact`, which the store
    /// enforces as well.
    @ViewBuilder
    private var menu: some View {
        if message.canReact && !isOffline {
            // A `ControlGroup` is what makes a menu lay its buttons out side by side instead
            // of stacking six near-identical emoji into six lines.
            ControlGroup {
                ForEach(QuickReaction.allCases) { reaction in
                    Button {
                        handlers.onToggleReaction(reaction.key)
                    } label: {
                        Text(reaction.key)
                    }
                }
            }
            .controlGroupStyle(.compactMenu)
        }

        if message.canReply {
            Button(action: handlers.onReply) {
                Label(Strings.Message.Menu.reply, systemImage: "arrowshape.turn.up.left")
            }
        }

        if message.canEdit && !isOffline {
            Button(action: handlers.onEdit) {
                Label(Strings.Message.Menu.edit, systemImage: "pencil")
            }
        }

        if let text = copyableText {
            Button {
                Clipboard.copy(text)
            } label: {
                Label(Strings.Message.Menu.copy, systemImage: "doc.on.doc")
            }
        }

        // Forwarding reaches another room, so it needs the network — offline there is nowhere for it
        // to go — and only the kinds a forward can faithfully rebuild are offered.
        if message.canForward, forwarding != nil, !isOffline {
            Button {
                isForwarding = true
            } label: {
                Label(Strings.Message.Menu.forward, systemImage: "arrowshape.turn.up.right")
            }
        }

        // Pinning names an event, so it is offered on the same messages a reply is: one the
        // server actually has. The homeserver may still refuse it — pinning is a change to the
        // room's state and needs the power level for it — and that refusal is said in an alert
        // rather than predicted here, because a menu item that quietly disappears teaches the
        // user nothing about why.
        if message.canReply && !isOffline {
            Button(action: handlers.onTogglePin) {
                Label(isPinned ? Strings.Message.Menu.unpin : Strings.Message.Menu.pin,
                      systemImage: isPinned ? "pin.slash" : "pin")
            }
        }

        if message.canDelete && !isOffline {
            Button(role: .destructive) {
                isConfirmingDelete = true
            } label: {
                Label(Strings.Message.Menu.delete, systemImage: "trash")
            }
        }

        // Reporting is for somebody else's message — you do not flag your own — and only one the
        // server has, since a report points at an event ID. A deleted message has nothing left to
        // report. Offline there is no moderator to reach.
        if !message.isOwn && !message.isDeleted && !isOffline {
            Button(role: .destructive) {
                isReporting = true
            } label: {
                Label(Strings.Message.Menu.report, systemImage: "exclamationmark.bubble")
            }
        }

        // Block the sender — someone else, and only when there is a block list to add them to.
        if !message.isOwn && blockStore != nil {
            Button(role: .destructive) {
                isConfirmingBlock = true
            } label: {
                Label(Strings.Message.Menu.block, systemImage: "hand.raised")
            }
        }

        // When it was sent, and — if it is gone — when it went. The clock beside the bubble
        // gives the hour and nothing else, which is all it has room for and all anybody needs
        // until the day they need the rest; this is where the rest is.
        //
        // Its own section, so the system rules a line above it and the facts do not read as
        // two more things to press.
        Section {
            fact(Strings.Message.Menu.sentAt(Self.exactly(message.timestamp)), systemImage: "clock")

            if let deletedAt = message.deletedAt {
                fact(Strings.Message.Menu.deletedAt(Self.exactly(deletedAt)), systemImage: "trash")
            }
        }
    }

    /// A line in the menu that says something rather than doing something.
    ///
    /// A disabled button, which is a peculiar way to write a label and the only one a menu
    /// understands: a bare `Text` among menu items is dropped on the floor. Disabled is also
    /// how it comes out looking right — greyed, secondary, and not pressable, which it should
    /// not be, because there is nothing here to press.
    private func fact(_ title: LocalizedStringResource, systemImage: String) -> some View {
        Button {} label: {
            Label(title, systemImage: systemImage)
        }
        .disabled(true)
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
    func messageActions(_ message: Message,
                        isPinned: Bool,
                        handlers: MessageHandlers) -> some View {
        modifier(MessageActions(message: message, isPinned: isPinned, handlers: handlers))
    }

    /// Lets the row be dragged toward the middle of the screen to answer it — see `SwipeToReply`.
    /// Goes on the whole row, not the content.
    func swipeToReply(_ message: Message,
                      dragsToward: HorizontalEdge,
                      onReply: @escaping () -> Void) -> some View {
        modifier(SwipeToReply(message: message, dragsToward: dragsToward, onReply: onReply))
    }
}
