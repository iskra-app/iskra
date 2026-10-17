import SwiftUI
import IskraCore
import IskraDesign

/// Everything you can *do* to a message, lifted off the shape it is drawn in.
///
/// A bubble and a compact line are two ways of showing the same message, and the long press
/// on them offers the same eight things either way: react, reply, edit, copy, forward, pin,
/// delete, report. None of that is a fact about the shape — so none of it lives with
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
/// separate modifier — see `SwipeToReply`. The compact row is the exception, and on purpose: a
/// plain line has no shape to say whose it is, so there the face, the name and the clock go up
/// with it — see `CompactMessageRow.heading`.
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

        /// Where UIKit had the conversation at the moment `rect` was measured — so that a message
        /// held while the room is still sliding in can be moved by however far it has slid since.
        /// See `WindowProbe`.
        var roomPosition: CGPoint?

        /// Everything the conversation tells this message about how to draw itself — whether
        /// there is a wallpaper behind it, how wide the room is, the reader's text size — kept
        /// so the copy the menu lifts can be told the same. See `EnvironmentTap`.
        var environment: EnvironmentValues?
    }

    /// Guarding a redaction behind a confirmation, because it cannot be undone and every
    /// other item in that menu can.
    @State private var isConfirmingDelete = false

    /// Whether "End the poll?" is up. Closing a poll cannot be undone, so it asks, as deleting does.
    @State private var isConfirmingEndPoll = false

    /// Whether the report form is up for this message.
    @State private var isReporting = false

    /// Whether the room picker for forwarding is up.
    @State private var isForwarding = false

    /// Whether "who reacted" is up — see `ReactorsSheet`.
    @State private var isShowingReactors = false

    /// The event's JSON, while the developer's sheet for it is up — see `BetaFeatures.showsEventSourceKey`.
    @State private var source: EventSource?

    /// Which of the two taps this message's finger turned out to be — see `MessageTaps`.
    @State private var taps = MessageTaps()

    /// Counts double taps, and exists only to be a thing that *changes*: `sensoryFeedback`
    /// fires on a change of value, and "the user did it again" is otherwise not one.
    @State private var quickTaps = 0

    /// Offline, a message can be read, quoted and copied — and nothing else. Reacting, editing,
    /// deleting and pinning are all changes to what the *room* holds, and a room offline is a room
    /// nobody can be told about. Replying is the exception, and only looks like one: a reply is a new
    /// message, and a new message goes into the send queue and leaves when the network does.
    @Environment(\.isOffline) private var isOffline

    /// The forward capability, for sending this message into another room.
    @Environment(\.forwarding) private var forwarding

    /// The account's stickers, for keeping a sticker somebody sent.
    @Environment(\.stickers) private var stickers

    /// The menu itself, which lives above the whole app — see `messageMenuLayer()`.
    @Environment(\.messageMenu) private var menu

    /// The conversation this message is in, if it is in one — see `WindowProbe`.
    @Environment(\.messageMenuRoom) private var room

    /// The emoji a double tap leaves. The user's, chosen once in settings and read by every
    /// row in every conversation — see `QuickReaction`.
    ///
    /// A `String`, because the setting is any emoji at all and not one of the six the menu bar
    /// offers. What is stored has always been the character itself, so a choice made before that
    /// was true reads back here unchanged.
    @AppStorage(QuickReaction.storageKey) private var quickReaction = QuickReaction.defaultKey

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
            } action: {
                anchor.rect = $0
                anchor.roomPosition = room?.position
            }
            // And the environment it is drawn in, for the same reason and in the same box.
            .background { EnvironmentTap { [anchor] in anchor.environment = $0 } }
            // Nothing happens to the bubble under a held finger — no sinking, no squeeze. It used
            // to give under the press as a countdown to the lift, and what that actually said was
            // that the message changes shape when touched; the one thing a message being picked up
            // must not do is stop looking like itself. The knock of the lift is the feedback.
            // Gone from its place while it is in the menu — picked up, not copied. See
            // `MessageMenuPresenter.liftedID`.
            .modifier(LeavesGapWhileLifted(id: message.id))
            // The hold and the double tap, each simultaneous with everything else on the screen —
            // see `hold` and `doubleTap`, where the three attempts it took to get there are
            // written down. The single tap still lands underneath, so a photograph still opens and
            // a round video still plays; the cost is that a single tap on those waits out the
            // double-tap interval, which is the price of the quick reaction being true of every
            // message rather than only of the ones with nothing else to tap.
            // The hold is UIKit's on the phone and SwiftUI's on the Mac, and that split is not
            // taste — see `MessageHold`, which has the measurements. A SwiftUI `LongPressGesture`
            // inside a `ScrollView` takes the touch and the list stops scrolling, whatever it is
            // attached with. The Mac has no such problem: scrolling there is a wheel and two
            // fingers on a trackpad, not a drag on the content, so nothing is being competed for.
            #if os(iOS)
            .overlay {
                MessageHold(duration: Theme.Timing.menuLift,
                            onPressingChanged: { _ in },
                            onHold: open)
            }
            #else
            .onLongPressGesture(minimumDuration: Theme.Timing.menuLift) {
                open()
            }
            #endif
            .simultaneousGesture(doubleTap)
            // Everything the menu offers, for VoiceOver too — swipe up or down on a message and
            // the rotor goes through them, as it does in Messages and Mail. The menu used to be the
            // system's `.contextMenu`, which VoiceOver exposes by itself; since the menu became
            // ours, a hold that VoiceOver cannot make was the only way in, and replying, reacting
            // or deleting was out of reach. The same `sections` as the menu, so the two cannot
            // disagree about what a message allows.
            .accessibilityActions { spokenActions }
            // The knock that says the reaction went. Without it a double tap on a message
            // whose pill appears a beat later feels like nothing happened.
            .sensoryFeedback(.impact(weight: .medium), trigger: quickTaps)
            // The arbiter for this row, and the one place it is created. It is per message on
            // purpose: a tap waiting inside one bubble has nothing to do with a tap in the next —
            // and `MessageRow` and `LocationView` read it, so if nobody put it here they would be
            // reading an environment value nobody set.
            .environment(\.messageTaps, taps)
            .onDisappear { taps.cancel() }
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
            .confirmationDialog(Text(Strings.Poll.endConfirmTitle),
                                isPresented: $isConfirmingEndPoll,
                                titleVisibility: .visible) {
                Button(String(app: Strings.Poll.end), role: .destructive, action: handlers.onEndPoll)
            } message: {
                Text(Strings.Poll.endConfirmMessage)
            }
            .sheet(isPresented: $isReporting) {
                ReportSheet(onReport: handlers.onReport)
            }
            .sheet(isPresented: $isForwarding) {
                if let forwarding {
                    ForwardPicker(message: message, forwarding: forwarding)
                }
            }
            .sheet(isPresented: $isShowingReactors) {
                if let load = handlers.loadReactors {
                    ReactorsSheet(reactions: message.reactions, load: load)
                }
            }
            .sheet(item: $source) { source in
                EventSourceSheet(json: source.json)
            }
    }

    /// Hands the message, and everything that can be done to it, to the menu above the app.
    ///
    /// The *content* goes with it — `content()` called a second time — so what lifts off the
    /// page is the real bubble rather than a picture of one: a video note goes on playing while
    /// the menu is open, and a photograph is still a photograph.
    /// The press that lifts the message into its menu, and the double tap that leaves a reaction.
    ///
    /// Two gestures, attached **simultaneously**, and every word of that has been the wrong way
    /// round at least once. What follows is the whole history, because three attempts were spent on
    /// this and each one moved the bug rather than fixing it.
    ///
    /// They started as a `.highPriorityGesture` double tap and an `.onLongPressGesture`. Priority
    /// was there for a real reason: SwiftUI gives the innermost gesture first refusal, so on a
    /// photograph — which has a tap of its own — the quick reaction was unreachable, and
    /// photographs are exactly what people react to. But priority in SwiftUI is not a preference,
    /// it is a *failure requirement*: every other recogniser, the enclosing scroll view's pan
    /// included, waits until the prioritised one has failed. A `TapGesture(count: 2)` does not fail
    /// when the finger moves; it fails on its own timeout, three quarters of a second later. So the
    /// press could not be recognised until then — the menu took the better part of a second to
    /// lift — and neither could the scroll.
    ///
    /// Fusing them into one `exclusively(before:)` gesture cured the lift, because the press was
    /// then tried first and claimed the touch at `menuLift` instead of waiting on a tap's timeout.
    /// It did nothing for the scroll, because the fused gesture was still attached at high priority
    /// and still contained the tap that takes three quarters of a second to fail.
    ///
    /// Simultaneous recognition is what removes the question rather than re-asking it: nothing
    /// waits for these, the pan scrolls whenever the finger goes down the screen, and a moving
    /// finger fails both of them by itself — one on distance, one on never getting its second tap.
    /// With no failure requirement left between them there is also nothing to fuse: the press and
    /// the tap are two separate gestures again, each recognised on its own terms, which is one
    /// dependency fewer to be wrong about.
    ///
    /// What simultaneity gives up is the suppression high priority threw in for free: a
    /// photograph's own tap now also recognises, so both of these say out loud what priority used
    /// to imply. The double tap tells the arbiter that a second tap arrived (`taps.double()`); the
    /// press tells it the touch was spent on the menu (`taps.suppress()`, in `open()`). See
    /// `MessageTaps`, which is where the ordering between a tap on a message and a tap on what is
    /// *inside* it lives now that it is nobody's side effect.
    private var doubleTap: some Gesture {
        TapGesture(count: 2).onEnded {
            // Whatever single tap is waiting inside this message — the photograph about to open,
            // the circle about to play — was the first half of this, and is called off here.
            // Before the guard below, because a reaction being refused is no reason to open a
            // picture nobody asked for. See `MessageTaps`.
            taps.double()

            // Offline the gesture is not merely refused, it is *silent* — and that is the whole
            // reason to guard it here as well as in the menu. A double tap that puts no pill on
            // the message reads as an app that did not notice the tap, so somebody would tap
            // again, harder, and go on tapping. See `isOffline`.
            guard message.canReact, !isOffline else { return }
            quickTaps += 1
            handlers.onToggleReaction(quickReaction)
        }
    }

    private func open() {
        // The finger that lifts off this press is not asking for the photograph underneath it.
        // Nothing is waiting yet at this moment — a single tap is scheduled when the finger comes
        // *up*, which is after the menu is already open — so this is not a cancellation but a
        // refusal of the tap that is about to arrive. See `MessageTaps.suppress`.
        taps.suppress()

        guard let menu, anchor.rect != .zero else { return }
        // Moved by however far the conversation has slid since it was measured — nothing at all,
        // unless the room is still arriving. See `WindowProbe`.
        var rect = anchor.rect
        if let then = anchor.roomPosition, let now = room?.position {
            rect = rect.offsetBy(dx: now.x - then.x, dy: now.y - then.y)
        }
        menu.present(MessageMenuPresentation(
            id: message.id,
            anchor: rect,
            isOwn: message.isOwn,
            canReact: message.canReact && !isOffline,
            mine: Set(message.reactions.filter(\.isMine).map(\.key)),
            content: AnyView(lifted),
            sections: sections,
            onReaction: handlers.onToggleReaction))
    }

    /// The message as the menu draws it: the same view, in the same environment.
    ///
    /// The menu is drawn above the whole app, and the conversation's environment does not reach
    /// up there — so a copy built from `content()` alone was a *different-looking* message: an
    /// opaque bubble where the room has a wallpaper (`hasWallpaper` is set by the room, not by the
    /// app), and whatever else the room tells its rows. It changed colour the instant it left the
    /// page, which is precisely what Telegram's never does. Handing it the row's own environment,
    /// whole, is what makes the thing in the menu the message rather than a likeness of it.
    ///
    /// Less one value: where the composer is. A message that has just been sent travels in from
    /// there (`ComposerTravel`), and a copy that inherited that would fly across the screen a
    /// second time the moment it was pressed.
    ///
    /// Both exceptions — and the page under the bubble, `bubbleIsLifted` — are written *into* the
    /// captured environment, not laid over it with modifiers of their own. `.environment(\.self,)`
    /// is the modifier nearest the content and so the last word: anything set outside it is
    /// overwritten by the row's own values, which is how the first version of this shipped with
    /// a lifted bubble that was still see-through.
    private var lifted: some View {
        var environment = anchor.environment ?? EnvironmentValues()
        environment.composerTextLeading = nil
        environment.bubbleIsLifted = true
        return content()
            .environment(\.self, environment)
    }

    /// The menu, read out: the quick reaction first — it is what a double tap does, and a double
    /// tap is VoiceOver's own "activate" — then the rest of the emoji behind "More reactions", which
    /// opens the real menu with its bar, then every verb. The dates are left out: they are facts,
    /// not things to do, and the menu shows them only as lines to read.
    @ViewBuilder
    private var spokenActions: some View {
        if message.canReact && !isOffline {
            let isMine = message.reactions.contains { $0.key == quickReaction && $0.isMine }
            Button(String(app: isMine ? Strings.Message.Menu.removeQuick(quickReaction)
                                      : Strings.Message.Menu.addQuick(quickReaction))) {
                handlers.onToggleReaction(quickReaction)
            }
            Button(String(app: Strings.Message.Menu.moreReactions)) { open() }
        }
        ForEach(sections.flatMap(\.actions).filter { $0.manner != .fact }) { action in
            Button(String(app: action.title), action: action.perform)
        }
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
        [MessageMenuSection(actions: reacted),
         MessageMenuSection(actions: doing),
         MessageMenuSection(actions: reporting),
         MessageMenuSection(actions: facts)]
            .filter { !$0.actions.isEmpty }
    }

    /// "5 reactions", above everything else in a group: who left what is the one question a pill
    /// of numbers cannot answer. Not in a personal chat, where there are two people and the pill
    /// already says which of them it was — `loadReactors` is nil there.
    private var reacted: [MessageMenuAction] {
        let count = message.reactions.reduce(0) { $0 + $1.count }
        guard handlers.loadReactors != nil, count > 0 else { return [] }
        return [MessageMenuAction(title: Strings.Message.Menu.reactors(count),
                                  systemImage: "face.smiling",
                                  perform: { isShowingReactors = true })]
    }

    private var doing: [MessageMenuAction] {
        var actions: [MessageMenuAction] = []

        if message.canReply {
            actions.append(MessageMenuAction(title: Strings.Message.Menu.reply,
                                             systemImage: "arrowshape.turn.up.left",
                                             perform: handlers.onReply))
        }

        // Answering in a thread rather than in the room: the same thread the line under the message
        // opens, started here when there is none yet. Only on something the server has.
        if message.canReply, message.threadRootID == nil, let onOpenThread = handlers.onOpenThread {
            actions.append(MessageMenuAction(title: Strings.Thread.replyInThread,
                                             systemImage: "bubble.left.and.text.bubble.right",
                                             perform: onOpenThread))
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

        // A sticker can be kept — put in the account's own pack, which nothing is uploaded for:
        // the pack points at the picture the event already points at. Only a plain one: see
        // `Attachment.asSticker`, which is nil for an encrypted file nobody could draw from a pack.
        if case let .sticker(attachment) = message.kind, let stickers, !isOffline,
           let sticker = attachment.asSticker {
            let isMine = stickers.isMine(sticker.url)
            actions.append(MessageMenuAction(title: isMine ? Strings.Stickers.remove : Strings.Stickers.add,
                                             systemImage: isMine ? "minus.circle" : "plus.circle",
                                             perform: {
                                                 Task {
                                                     if isMine {
                                                         await stickers.remove(sticker)
                                                     } else {
                                                         await stickers.add(sticker)
                                                     }
                                                 }
                                             }))
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

        // Several at once: forward them together, copy them as one piece of text, delete a run of
        // mistakes. Telegram's "Select", with this message already ticked.
        if let onSelect = handlers.onSelect, message.delivery?.hasFailed != true {
            actions.append(MessageMenuAction(title: Strings.Message.Menu.select,
                                             systemImage: "checkmark.circle",
                                             perform: onSelect))
        }

        // For whoever is chasing a message that draws wrong — Beta → for developers.
        if let loadSource = handlers.loadSource {
            actions.append(MessageMenuAction(title: Strings.Beta.viewSource,
                                             systemImage: "curlybraces",
                                             perform: {
                                                 source = EventSource(json: loadSource() ?? String(app: Strings.Beta.noSource))
                                             }))
        }

        // Taking a vote back: a response with no answers in it, which the poll counts as no vote at
        // all (MSC3381). Only while the poll is open, and only for somebody who has voted.
        if case let .poll(poll) = message.kind, poll.hasVoted, !poll.isEnded, !isOffline {
            actions.append(MessageMenuAction(title: Strings.Poll.retract,
                                             systemImage: "arrow.uturn.backward.circle",
                                             perform: { handlers.onVote([]) }))
        }

        // Only the sender may close a poll — the room ignores an end from anybody else — and only
        // one the server has.
        if message.canEndPoll && !isOffline {
            actions.append(MessageMenuAction(title: Strings.Poll.end,
                                             systemImage: "stop.circle",
                                             perform: { isConfirmingEndPoll = true }))
        }

        return actions
    }

    /// The red ones, kept together at the foot of the menu so that nothing irreversible sits
    /// next to something that is not.
    private var reporting: [MessageMenuAction] {
        var actions: [MessageMenuAction] = []

        // Your own, or — for a moderator the room allows it — anybody's.
        if (message.canDelete || (handlers.canDeleteOthers && message.canBeDeletedByModerator)) && !isOffline {
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

        // When it was read is deliberately not here for the moment, though `Message.readAt` is
        // worked out and kept as carefully as ever — putting the line back is putting these five
        // lines back, and `Strings.Message.Menu.readAt` is still written in both languages.
        //
        // What a receipt reports is "I had read this far by 14:03", so the same sentence means
        // two slightly different things depending on whether it is the message the receipt names
        // or one above it, and the menu had no way to say which it was holding. Better silence
        // than a time nobody can tell how to read.

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
/// **Simultaneous, and that is the whole of why the conversation scrolls.** This was `.gesture(_:)`,
/// with a `minimumDistance` and a direction check, and the comment here said that kept it out of
/// the way of scrolling. It did not, and the two guards are why it looked as though it should.
///
/// `minimumDistance` postpones *recognition*; it does not restrict it to a direction. Eighteen
/// points in any direction at all — straight down the screen included — and this gesture has
/// recognised, which in SwiftUI means the enclosing scroll view's pan has lost the touch to it.
/// The direction check then runs, decides the drag is vertical, and declines to move the row: so
/// the message stays still, the list stays still, and the finger is holding a conversation that
/// cannot be scrolled. The check was reading the right number one step too late — by then the
/// question it answers has already been decided against the scroll view.
///
/// Simultaneous recognition never poses the question. The pan scrolls whenever the finger goes
/// down the screen, this gesture runs alongside it, and the direction check keeps its original job:
/// deciding whether the *row* moves. Which of the two owns a drag is now latched on the first
/// movement, so a swipe that starts vertical stays the scroll view's for its whole length.
///
/// The row is inset from the screen edge (avatar, margins) so the incoming-message swipe does not
/// start where the system's back-edge gesture lives — a thing to confirm on a device, where that
/// gesture actually exists.
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

    /// Whose drag this is, decided once on the first movement and held until the finger lifts.
    ///
    /// Asked afresh on every event — which is what it was — the answer can change mid-drag: a
    /// finger that starts down the screen and curls sideways would begin scrolling the conversation
    /// and then start dragging a message out of it at the same time. A swipe is one act, and which
    /// act it is is settled by how it starts.
    @State private var isScrolling: Bool?

    /// The distance past which letting go replies.
    private static let threshold: CGFloat = 56

    func body(content: Content) -> some View {
        if message.canReply {
            content
                .offset(x: dragOffset)
                // The arrow waits on the edge the message is coming away from, which is the
                // opposite of the one it moves toward.
                .background(alignment: dragsToward == .leading ? .trailing : .leading) { hint }
                .simultaneousGesture(gesture)
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
                // than horizontal belongs to the scroll view — which is now free to take it, and
                // takes it whatever this gesture decides — and one heading for the edge is not a
                // reply either way.
                if isScrolling == nil {
                    isScrolling = abs(value.translation.height) >= abs(value.translation.width)
                }
                guard isScrolling == false else { return }
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
                isScrolling = nil
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

/// Keeps the environment a message is drawn in, so the menu can draw its copy in the same one.
///
/// A view of its own, behind the message, so that it is *this* body that re-runs when the
/// environment changes and not the message's — the box is written, nothing is redrawn.
private struct EnvironmentTap: View {
    let keep: (EnvironmentValues) -> Void
    @Environment(\.self) private var environment

    var body: some View {
        // A write from a body, and harmless only because of where it goes: into a box SwiftUI is
        // not watching, so it changes nothing on screen and cannot start another pass. See
        // `MessageActions.anchor`.
        keep(environment)
        return Color.clear
    }
}

/// Empties a message's place in the conversation while the message itself is up in the menu.
///
/// A modifier that reads the presenter, rather than the row reading it, so that opening a menu
/// re-runs this small body on every message on screen and not every message's bubble.
private struct LeavesGapWhileLifted: ViewModifier {
    let id: String

    @Environment(\.messageMenu) private var menu

    func body(content: Content) -> some View {
        let isAway = menu?.liftedID == id
        content
            .opacity(isAway ? 0 : 1)
            // Never faded: the gap opens in the frame the copy appears, and closes in the frame it
            // lands — a fade either way is a moment with two messages, or with none.
            .animation(nil, value: isAway)
    }
}
