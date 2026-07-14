import SwiftUI
import IskraCore
import IskraDesign

/// One message in the timeline.
struct MessageRow: View {
    let message: Message

    /// In a conversation with one other person there is no one to tell apart, so the
    /// avatar and the name above every incoming message are noise. In a room with
    /// several people they are the only way to know who said what, so they stay.
    let isDirectChat: Bool

    /// Starts the room's send queue again, for the one message shape that can ask for it:
    /// a failure the SDK called recoverable. A row cannot do this itself — only the store
    /// owns the room — so, like sign-out, it is reported upward rather than done here.
    var onRetry: () -> Void = {}

    /// Adds an emoji, or takes it back if it is already ours. One callback for both,
    /// because a reaction is a toggle — see `TimelineStore.toggleReaction`.
    var onToggleReaction: (String) -> Void = { _ in }

    /// Takes the message back for everyone. Only ever offered where `Message.canDelete`.
    var onDelete: () -> Void = {}

    /// Throws away a message that never left the device. A different act from `onDelete`,
    /// which redacts an event the room has already seen — see `TimelineStore.discard`.
    var onDiscard: () -> Void = {}

    /// Starts an answer to this message. The composer, not the row, is where the answer is
    /// actually written — so this only says which message the user chose.
    var onReply: () -> Void = {}

    /// Goes back and changes what was written. Only the user's own words — see `Message.canEdit`.
    var onEdit: () -> Void = {}

    /// Pins the message to the top of the room, or takes it off again. One callback, because
    /// the user is pressing one item whose word depends on where the message already is.
    var onTogglePin: () -> Void = {}

    /// Whether this message is currently pinned, which is the whole of what the menu item
    /// needs to know to say the right word.
    var isPinned: Bool = false

    /// Goes to the message this one is answering. Pressed on the quote inside the bubble; only
    /// `RoomView` can actually scroll the conversation, so it is reported upward.
    var onOpenReply: (String) -> Void = { _ in }

    /// Whether the conversation has just jumped *to* this message, and it is briefly lit so that
    /// the eye can find it.
    ///
    /// The scroll alone is not an answer. Pressing a quote lands the message somewhere in the
    /// middle of a screenful of other messages, all of them looking exactly like it, and the user
    /// is left to work out which of them they were sent to. Owned by `RoomView`, because it is a
    /// fact about the conversation — only one message in it is lit — and not about the row.
    var isHighlighted: Bool = false

    @Environment(\.accent) private var accent

    /// Guarding a redaction behind a confirmation, because it cannot be undone and every
    /// other item in that menu can.
    @State private var isConfirmingDelete = false

    /// The emoji a double tap leaves. The user's, chosen once in settings and read by every
    /// row in every conversation — see `QuickReaction`.
    @AppStorage(QuickReaction.storageKey) private var quickReaction: QuickReaction = .default

    /// Counts double taps, and exists only to be a thing that *changes*: `sensoryFeedback`
    /// fires on a change of value, and "the user did it again" is otherwise not one.
    @State private var quickTaps = 0

    /// How wide the conversation is, measured by `RoomView` and handed down. A playing video
    /// note grows to fill it.
    ///
    /// The row used to measure *itself* for this, and that froze the app: a row is as wide as
    /// what is in it, and what was in it was being sized from the row's width — so every pass
    /// of the view graph rewrote the state that started the pass. See
    /// `EnvironmentValues.timelineWidth`.
    @Environment(\.timelineWidth) private var timelineWidth

    /// Whether this is a phone-shaped layout. A playing video note fills the width of a phone
    /// and merely doubles on a Mac or an iPad — see `playingDiameter`.
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// Who sent it is said by the side of the screen and, in a room, by the name above
    /// the bubble. Nothing else needs to repeat it.
    private var showsSender: Bool {
        !message.isOwn && !isDirectChat
    }

    var body: some View {
        // The message and its emoji are two elements stacked, not one: VoiceOver flattens
        // the message into a single label it can read, and the reaction pills have to stay
        // outside that — a combined element swallows the buttons inside it, and a blind
        // user would be the only one who could see the reactions and not press them.
        //
        // Zero spacing, because the emoji do not sit *below* the bubble — they climb back
        // onto it. See `reactions`.
        VStack(alignment: message.isOwn ? .trailing : .leading, spacing: 0) {
            bubbleRow

            if !message.reactions.isEmpty {
                reactions
            }
        }
        .padding(.top, message.isContinuation ? Theme.Spacing.withinRun : Theme.Spacing.betweenSenders)
        // Lit, when the conversation has just been sent here. The wash runs the full width of the
        // row and out into the margins the timeline keeps on either side — it is the *row* that
        // has been found, and a glow that stopped at the bubble's edge would be one more shape in
        // a column of shapes rather than a torch shone on one of them.
        //
        // The accent, faintly, and not a yellow of its own: this is the app pointing at something,
        // and the app points in one colour.
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .fill(accent.color.opacity(isHighlighted ? 0.16 : 0))
                .padding(.horizontal, -Theme.Spacing.close)
                .allowsHitTesting(false)
        }
        // Slower than a reaction, and it has to be: this one is meant to be *caught*, and a wash
        // that snapped on and off would be over before the eye arrived from the quote it was
        // pressed on. It fades out on its own — see `RoomView`, which is what puts the light out.
        .animation(.smooth(duration: Theme.Timing.reaction * 2), value: isHighlighted)
        // Reactions arrive from other people, unannounced, while you are reading. Popping
        // one into existence under a message moves every message below it by a row with no
        // warning; growing it in says what happened. One `value:` for the whole row, so a
        // pill that only changes its count animates too.
        .animation(.smooth(duration: Theme.Timing.reaction), value: message.reactions)
        // A redaction does not remove the message; it replaces what it was with the fact
        // that it is gone. So the bubble does not disappear, it *becomes* the grey line —
        // a paragraph of text, or a photo, shrinking down to five italic words. Without
        // this the swap is instantaneous and the conversation below it jumps up by however
        // tall the message used to be, which reads as a glitch rather than as a deletion.
        .animation(.smooth(duration: Theme.Timing.deletion), value: message.kind)
        // And when the row really does leave — a message thrown out of the send queue,
        // which never reached anyone and leaves no trace behind it — it shrinks away
        // instead of blinking out. The animation that drives this belongs to the list, not
        // to the row: see `RoomView`.
        .transition(.asymmetric(insertion: .opacity,
                                removal: .scale(scale: 0.85).combined(with: .opacity)))
    }

    /// Whether the bubble has something inside it that has to be *pressed* — a play button, a
    /// photograph that opens, a file that opens.
    ///
    /// It decides how the row is presented to VoiceOver, and the decision matters more than it
    /// looks. `.combine` flattens a row into one element with one sentence, which is exactly right
    /// for a message made of words: "Аня: привет, 14:32" is one thought, and making somebody swipe
    /// through three fragments to hear it would be worse. But flattening a row also flattens the
    /// button inside it — and for a voice message, a video note, a photograph or a file, that
    /// button is the *entire message*. It was possible to hear that Аня had sent a voice message
    /// and impossible to play it.
    ///
    /// So a row whose content can be pressed is a container to be entered rather than a sentence
    /// to be read. Everything else stays one sentence.
    private var hasPressableContent: Bool {
        switch message.kind {
        case .voice, .audio, .image, .video, .videoNote, .file: true
        default: false
        }
    }

    @ViewBuilder
    private var bubbleRow: some View {
        let row = bubbleRowContent

        if hasPressableContent {
            row.accessibilityElement(children: .contain)
        } else {
            row
                .accessibilityElement(children: .combine)
                .accessibilityLabel(accessibilityLabel)
        }
    }

    private var bubbleRowContent: some View {
        HStack(alignment: .bottom, spacing: Theme.Spacing.close) {
            if message.isOwn {
                Spacer(minLength: emptyColumn)
                // The clock sits on the outside of the bubble — away from the edge the
                // conversation is anchored to — so a column of times lines up quietly
                // beside the messages instead of cutting between them.
                timestamp
            }

            // Only the first message in a run carries an avatar; the rest are indented
            // to line up under it.
            if showsSender {
                if message.isContinuation {
                    Color.clear.frame(width: Theme.Size.avatarSmall)
                } else {
                    Avatar(name: message.senderName, url: message.senderAvatarURL, size: Theme.Size.avatarSmall)
                }
            }

            VStack(alignment: message.isOwn ? .trailing : .leading, spacing: Theme.Spacing.tight) {
                if showsSender && !message.isContinuation {
                    Text(message.senderName)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.leading, Theme.Spacing.close)
                }

                if case let .failed(failure)? = message.delivery {
                    // The badge is centred on the bubble, not dropped onto its baseline
                    // like the clock. It is an alarm, not a footnote, and an alarm that
                    // lines up with the bottom edge of a tall bubble reads as belonging to
                    // the last line of text rather than to the whole message. Its own
                    // `HStack` is what buys that: the row around it stays bottom-aligned,
                    // so the clock is exactly where it was.
                    HStack(alignment: .center, spacing: Theme.Spacing.close) {
                        SendFailureBadge(failure: failure, onRetry: onRetry, onDiscard: onDiscard)
                        actionableContent
                    }
                } else {
                    actionableContent
                }
            }

            if !message.isOwn {
                timestamp
                Spacer(minLength: emptyColumn)
            }
        }
    }

    /// The bubble, with everything you can do to it hanging off it.
    ///
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
    private var actionableContent: some View {
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
                guard message.canReact else { return }
                quickTaps += 1
                onToggleReaction(quickReaction.key)
            })
            // The knock that says the reaction went. Without it a double tap on a message
            // whose pill appears a beat later feels like nothing happened.
            .sensoryFeedback(.impact(weight: .medium), trigger: quickTaps)
            .contextMenu { menu }
            .confirmationDialog(Text(Strings.Message.Menu.deleteConfirmTitle),
                                isPresented: $isConfirmingDelete,
                                titleVisibility: .visible) {
                Button(String(app: Strings.Message.Menu.delete), role: .destructive, action: onDelete)
            } message: {
                Text(Strings.Message.Menu.deleteConfirmMessage)
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
        if message.canReact {
            // A `ControlGroup` is what makes a menu lay its buttons out side by side instead
            // of stacking six near-identical emoji into six lines.
            ControlGroup {
                ForEach(QuickReaction.allCases) { reaction in
                    Button {
                        onToggleReaction(reaction.key)
                    } label: {
                        Text(reaction.key)
                    }
                }
            }
            .controlGroupStyle(.compactMenu)
        }

        if message.canReply {
            Button(action: onReply) {
                Label(Strings.Message.Menu.reply, systemImage: "arrowshape.turn.up.left")
            }
        }

        if message.canEdit {
            Button(action: onEdit) {
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

        // Pinning names an event, so it is offered on the same messages a reply is: one the
        // server actually has. The homeserver may still refuse it — pinning is a change to the
        // room's state and needs the power level for it — and that refusal is said in an alert
        // rather than predicted here, because a menu item that quietly disappears teaches the
        // user nothing about why.
        if message.canReply {
            Button(action: onTogglePin) {
                Label(isPinned ? Strings.Message.Menu.unpin : Strings.Message.Menu.pin,
                      systemImage: isPinned ? "pin.slash" : "pin")
            }
        }

        if message.canDelete {
            Button(role: .destructive) {
                isConfirmingDelete = true
            } label: {
                Label(Strings.Message.Menu.delete, systemImage: "trash")
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

    /// The emoji under the bubble — aligned to the side the message is on, indented past
    /// the avatar so they sit under the *bubble* rather than under the face beside it, and
    /// tucked up over the bubble's bottom edge so they read as part of it.
    ///
    /// The overlap is a negative padding rather than an offset, deliberately: an offset
    /// would move the pills without telling the layout, leaving a bubble-shaped hole of
    /// empty space behind them and the next message pushed down past it. A negative padding
    /// moves them *and* closes the gap they came from.
    private var reactions: some View {
        FlowLayout(spacing: Theme.Spacing.tight,
                   alignment: message.isOwn ? .trailing : .leading) {
            ForEach(message.reactions) { reaction in
                ReactionPill(reaction: reaction) {
                    onToggleReaction(reaction.key)
                }
                // Each pill grows from nothing rather than fading in on the spot, so an
                // emoji someone else just left reads as arriving.
                .transition(.scale(scale: 0.3).combined(with: .opacity))
            }
        }
        .padding(.leading, leadingInset)
        .padding(.trailing, message.isOwn ? Theme.Spacing.reactionInset : 0)
        .padding(.top, -Theme.Spacing.reactionOverlap)
        // Drawn after the bubble and therefore over it — which is the whole point, and is
        // only true because this comes second in the stack.
        .zIndex(1)
    }

    /// Two different things, added together, and worth keeping apart in the head.
    ///
    /// The first is the avatar's column: without it the pills would line up under the
    /// sender's face rather than under the words they are reacting to. The second is the
    /// step in from the bubble's own leading edge — and that one is only spent on someone
    /// else's message, because your own steps in from the *right* instead.
    private var leadingInset: CGFloat {
        let avatarColumn = showsSender ? Theme.Size.avatarSmall + Theme.Spacing.close : 0
        return avatarColumn + (message.isOwn ? 0 : Theme.Spacing.reactionInset)
    }

    /// The time the message was sent, and — on your own messages — how far it has got.
    ///
    /// Beside the bubble rather than inside it: a time tucked into the corner of a
    /// bubble has to fight the last line of text for room, and loses that fight badly
    /// when the last line is long.
    private var timestamp: some View {
        HStack(spacing: Theme.Spacing.tight) {
            // "изменено" goes here rather than inside the bubble, and that is not where other
            // messengers put it — they have the clock in the bubble's corner to sit it beside.
            // Ours is outside, in this quiet grey column of facts about the message, and
            // "changed after it was sent" is exactly such a fact. Inside the bubble it would
            // have to fight the last line of text for room, or force a line of its own under a
            // one-word message.
            if message.isEdited {
                Text(Strings.Message.edited)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Text(message.timestamp, format: .dateTime.hour().minute())
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)

            // A failure is not a delivery state among others, and it does not belong in
            // this quiet grey row: it gets the badge beside the bubble instead.
            if message.isOwn, let delivery = message.delivery, !delivery.hasFailed {
                DeliveryTick(status: delivery)
            }
        }
        // The clock must never squeeze the message it belongs to.
        .fixedSize()
        .padding(.bottom, Theme.Spacing.tight)
    }

    @ViewBuilder
    private var content: some View {
        switch message.kind {
        case let .text(body):
            bubble { Text(body) }

        case let .notice(body):
            bubble { Text(body).italic() }

        case let .emote(body):
            quoted {
                Text(body)
                    .font(.callout.italic())
                    .foregroundStyle(.secondary)
            }

        case let .videoNote(attachment):
            // The signature shape: a circle, not a bubble. No bubble background, so
            // no rounded-rectangle peeking out behind the mask.
            //
            // How big it may grow is worked out here rather than inside the circle, because
            // it is a fact about the row: the whole width, less the clock beside the bubble
            // and — in a group, on somebody else's message — the avatar in front of it. Take
            // the *whole* width and the circle would push one of the two off the screen.
            quoted {
                VideoNoteView(attachment: attachment, playingDiameter: playingDiameter)
            }

        case let .voice(attachment, waveform):
            bubble { VoiceMessageView(attachment: attachment, waveform: waveform, isOwn: message.isOwn) }

        case let .image(attachment):
            quoted {
                PictureBubble(attachment: attachment, isOwn: message.isOwn, isPlayable: false,
                              sender: senderTitle, timestamp: message.timestamp)
            }

        case let .video(attachment):
            quoted {
                PictureBubble(attachment: attachment, isOwn: message.isOwn, isPlayable: true,
                              sender: senderTitle, timestamp: message.timestamp)
            }

        case let .audio(attachment):
            FileBubble(attachment: attachment, systemImage: "waveform", isOwn: message.isOwn)

        case let .file(attachment):
            FileBubble(attachment: attachment, systemImage: "doc", isOwn: message.isOwn)

        case let .location(location):
            quoted {
                LocationBubble(location: location, isOwn: message.isOwn)
            }

        case .unreadable:
            // Not an error the user caused, and not one they can fix. Say what
            // happened without the word "decrypt".
            bubble {
                Label { Text(Strings.Message.unreadable) } icon: { Image(systemName: "lock.slash") }
                    .font(.footnote)
            }

        case .deleted:
            // Not `bubble`: a message that is gone is drawn as an outline with nothing in
            // it — see `deletedBubble`.
            Text(Strings.Message.deleted)
                .font(.footnote.italic())
                .deletedBubble()

        case .unsupported:
            bubble {
                Text(Strings.Message.unsupported)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The gap a message must leave on the far side of the conversation, so that a long one is
    /// visibly *from* somebody rather than a paragraph spanning the screen.
    ///
    /// It is what is left of the width once the message has taken the nine tenths it is allowed
    /// — and the clock, which stands outside the bubble but is part of the message all the
    /// same, is counted as the message's. So the gap is a *tenth of the conversation, less the
    /// clock's column*, and on a phone that arithmetic comes out at nothing: the clock is
    /// already wider than the tenth, and the column of times is itself the gap. That is the
    /// intended answer and not a degenerate one — 56pt of quiet beside a bubble is plenty on a
    /// screen 390pt wide, and it buys the bubble the room the flat 60pt was taking from it.
    /// On a Mac, where a tenth is a hundred points, the gap reappears and does the job it was
    /// written for.
    ///
    /// A video note is the exception. A playing note takes the whole width, and this floor is
    /// the one thing that would not let it: it is a *minimum*, so the row would honour it by
    /// pushing the clock off the screen rather than by drawing a smaller circle. There is
    /// nothing for the gap to protect here anyway — a circle is not a wall of text, and the
    /// shape says whose it is well enough on its own.
    ///
    /// Nothing at all until the conversation has been measured, which lasts one layout pass.
    private var emptyColumn: CGFloat {
        if case .videoNote = message.kind { return 0 }
        return max(0, timelineWidth * (1 - Theme.Size.bubbleWidthFraction) - Theme.Size.clockColumn)
    }

    /// How big a video note goes while it plays.
    ///
    /// On a phone it takes the width of the conversation, because the conversation is the
    /// whole screen and there is nothing else there to look at. On a Mac or an iPad there is:
    /// the window is wide, the room list is beside it, and a circle stretched across all of
    /// that would be a face the size of a dinner plate with the chat cowering around it. So on
    /// a regular-width layout it simply doubles — big enough to watch, still a message in a
    /// conversation rather than a takeover.
    ///
    /// Never bigger than the room actually available, and never smaller than a resting circle:
    /// on a narrow window either of those would mean "growing" it into something smaller than
    /// it was.
    private var playingDiameter: CGFloat {
        let avatarColumn = showsSender ? Theme.Size.avatarSmall + Theme.Spacing.close : 0
        let available = timelineWidth - avatarColumn - Theme.Size.clockColumn

        let wanted = horizontalSizeClass == .compact
            ? available
            : min(available, Theme.Size.videoNote * Theme.Size.videoNoteGrowth)

        return max(Theme.Size.videoNote, wanted)
    }

    /// A bubble, with the message it is answering quoted at the top of it.
    ///
    /// Inside the bubble, not above it. A quote is part of what the message *says* — read on
    /// its own, "yes, and it's at six" is not a sentence — so it travels with the words rather
    /// than floating over them. The bubble grows to hold it, which is exactly right: an answer
    /// carrying its question is a bigger thing than a bare line of text.
    private func bubble(@ViewBuilder _ inner: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.close) {
            quote

            inner()
                .font(.body)
        }
        .messageBubble(isOwn: message.isOwn)
    }

    /// The same quote for the messages that have no bubble to put it in — a photo, a circle, an
    /// emote. It gets a small bubble of its own and sits above them.
    private func quoted(@ViewBuilder _ inner: () -> some View) -> some View {
        VStack(alignment: message.isOwn ? .trailing : .leading, spacing: Theme.Spacing.tight) {
            if message.replyTo != nil {
                quote
                    .messageBubble(isOwn: message.isOwn)
            }

            inner()
        }
    }

    @ViewBuilder
    private var quote: some View {
        if let reply = message.replyTo {
            ReplyQuote(reply: reply, isOwn: message.isOwn) {
                onOpenReply(reply.eventID)
            }
        }
    }

    /// Who sent it, in the one form that works when the message is looked at away from the
    /// side of the screen it was on: a name, and "you" where the name would be your own.
    ///
    /// The word is `Spoken.you` — the one VoiceOver reads out — and it is deliberately not a
    /// second string with the same two letters in it. A translation duplicated is a translation
    /// that drifts, and there is no sentence in which the app would want to call the user one
    /// thing aloud and another on screen.
    private var senderTitle: String {
        message.isOwn ? String(app: Strings.Message.Spoken.you) : message.senderName
    }

    private var accessibilityLabel: String {
        let who = senderTitle

        // A message body is the sender's own words, so it is read back as written.
        // Everything else is a description of what they did, and is translated.
        let what: String = switch message.kind {
        case let .text(body): body
        case let .notice(body): body
        case let .emote(body): body
        case .image: String(app: Strings.Message.Spoken.sentPhoto)
        case .video: String(app: Strings.Message.Spoken.sentVideo)
        case .videoNote: String(app: Strings.Message.Spoken.sentVideoNote)
        case .voice: String(app: Strings.Message.Spoken.sentVoice)
        case .audio: String(app: Strings.Message.Spoken.sentAudio)
        case .file: String(app: Strings.Message.Spoken.sentFile)
        case .location: String(app: Strings.Message.Spoken.sentLocation)
        case .unreadable: String(app: Strings.Message.Spoken.sentUnreadable)
        case .deleted: String(app: Strings.Message.Spoken.deletedMessage)
        case .unsupported: String(app: Strings.Message.Spoken.sentUnsupported)
        }

        // The row is one combined element, so the badge's own button is flattened into it
        // and VoiceOver never lands on it. The reason therefore has to be said here, or a
        // blind user would be the only one who cannot find out why nothing was delivered.
        if case let .failed(failure)? = message.delivery {
            return "\(who): \(what). \(String(app: Strings.Message.Delivery.failed)). \(String(localized: failure.explanation))"
        }
        return "\(who): \(what)"
    }
}

/// One emoji under a message, and how many people have left it.
///
/// A button, and a toggle: pressing one you have already left takes it back. No pill is
/// outlined and none is tinted: yours used to be filled in the accent colour and ringed in it,
/// and a row of those under a busy message was a row of coloured buttons shouting over the
/// words above them. A reaction is a footnote, and it should look like one.
///
/// Which are yours is still said, and said in weight rather than in colour — the same grey,
/// a tone heavier (`Color.ownReaction`). That reads at a glance in a row of pills and
/// disappears completely when you are not looking for it, which is the whole idea. The count
/// on top of it keeps the accent, so a busy reaction says "yours" twice; a reaction only you
/// have left, which has no count to draw, still says it once.
///
/// No glass. A reaction is content, it sits on content, and the HIG keeps Liquid Glass in
/// the navigation layer — see `IskraDesign/Glass.swift`.
private struct ReactionPill: View {
    let reaction: MessageReaction
    let onToggle: () -> Void

    @Environment(\.accent) private var accent

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: Theme.Spacing.tight) {
                Text(reaction.key)
                    .font(.caption)

                // One person is what a lone emoji already says. The number appears when
                // there is something to count.
                if reaction.count > 1 {
                    Text(reaction.count, format: .number)
                        .font(.caption2.weight(.medium).monospacedDigit())
                        .foregroundStyle(reaction.isMine ? AnyShapeStyle(accent.color) : AnyShapeStyle(.secondary))
                }
            }
            .padding(.horizontal, Theme.Spacing.close)
            .padding(.vertical, Theme.Spacing.tight)
            // Two fills, and the opaque one underneath is load-bearing. The pill overlaps the
            // bubble, and the grey above is translucent — laid straight over a blue bubble it
            // would take its colour and turn to mud. The page's own background goes down
            // first, so the pill sits *on* the bubble rather than bleeding through it.
            .background {
                Capsule()
                    .fill(.background)
                    .overlay {
                        Capsule().fill(reaction.isMine ? Color.ownReaction : Color.incomingBubble)
                    }
            }
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(Strings.Message.Menu.reaction(reaction.key, reaction.count)))
        // What pressing it will do, which is the one thing the pill's appearance cannot
        // say out loud.
        .accessibilityHint(Text(reaction.isMine ? Strings.Message.Menu.removeReaction : Strings.Message.Menu.addReaction))
        .accessibilityAddTraits(reaction.isMine ? [.isButton, .isSelected] : .isButton)
    }
}

/// Sending, sent, read. Shown only on your own messages, and never as a raw word.
private struct DeliveryTick: View {
    let status: DeliveryStatus

    var body: some View {
        Group {
            switch status {
            case .sending:
                Image(systemName: "clock")
            case .sent:
                Image(systemName: "checkmark")
            case .read:
                Image(systemName: "checkmark.circle.fill")
            case .failed:
                // Never drawn: `MessageRow` sends failures to `SendFailureBadge`. Progress
                // is worth a whisper; a message that never left is not.
                EmptyView()
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .accessibilityLabel(Text(label))
    }

    private var label: LocalizedStringResource {
        switch status {
        case .sending: Strings.Message.Delivery.sending
        case .sent: Strings.Message.Delivery.sent
        case .read: Strings.Message.Delivery.read
        case .failed: Strings.Message.Delivery.failed
        }
    }
}

/// A message that did not go. Red, filled, and big enough to be believed.
///
/// It is a button because it used to look like one and do nothing: an exclamation mark you
/// can press and that answers nothing is worse than no mark at all, because it teaches the
/// user that the app knows something it will not tell them. Pressing it now says what is
/// wrong and what to do — and on the Mac hovering says it too, without a click.
private struct SendFailureBadge: View {
    let failure: SendFailure

    /// Sends this one message again. Only ever offered where that can work — see
    /// `SendFailure.canRetry`.
    let onRetry: () -> Void

    /// Throws the message away. Always offered, because it always works.
    let onDiscard: () -> Void

    @State private var isShowingReason = false

    /// What the hit area needs on each side to reach Apple's 44pt floor around a 20pt badge.
    private var touchInset: CGFloat {
        (Theme.Size.minimumTapTarget - Theme.Size.failureBadge) / 2
    }

    var body: some View {
        Button {
            isShowingReason = true
        } label: {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: Theme.Size.failureBadge))
                // Palette, so the disc is red and the mark punched out of it in white.
                // A red glyph on the app's own background would be a thin, apologetic
                // thing; a filled disc is what an unsent message deserves.
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .red)
                // The badge is 20pt across and a finger is not. The padding grows the hit
                // area to the 44pt floor, and the negative padding then takes that space
                // back out of the *layout* — the touch target stays big while the badge
                // sits close to the bubble instead of holding a 44pt column open beside it.
                .padding(touchInset)
                .contentShape(.circle)
                .padding(-touchInset)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isShowingReason) {
            SendFailureReason(failure: failure) {
                isShowingReason = false
                onRetry()
            } onDiscard: {
                isShowingReason = false
                onDiscard()
            }
            // Without this an iPhone turns the popover into a half-height sheet, which is
            // a whole ceremony for one sentence.
            .presentationCompactAdaptation(.popover)
        }
        // The Mac gets the same sentence on hover; VoiceOver takes it as a hint.
        .help(Text(failure.explanation))
        .accessibilityLabel(Text(Strings.Message.Delivery.failed))
        .accessibilityHint(Text(failure.explanation))
    }
}

/// What the badge says when pressed: what went wrong, a way to send the message again where
/// that would achieve something, and — always — a way to be rid of it.
///
/// Its own view, and not `internal` by accident: a popover cannot be rendered offscreen, so
/// this is the only way its layout can be looked at in a test rather than by tapping a
/// simulator and hoping.
struct SendFailureReason: View {
    let failure: SendFailure
    let onRetry: () -> Void
    let onDiscard: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.close) {
            Text(Strings.Room.sendFailedTitle)
                .font(.headline)
            Text(failure.explanation)
                .font(.callout)
                .foregroundStyle(.secondary)

            // Stacked, not side by side. Two labelled buttons in Russian do not fit across
            // 280pt, and a popover that truncates the way out of a stuck message is worse
            // than one that is a row taller. Full width apiece, so each is also a tap target
            // the size of the sentence above it.
            VStack(spacing: Theme.Spacing.close) {
                // Sending again is offered only where it can achieve something. On a file
                // that is gone, or a type the server will never accept, the queue would pick
                // the message up, fail on the very same thing, and hand back the very same
                // red badge — a button that does that is worse than no button, because it
                // looks like the app is working on a problem it cannot touch.
                if failure.canRetry {
                    Button(action: onRetry) {
                        Label(Strings.Message.Delivery.sendAgain, systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }

                // Always offered, and on the failures above it is the only thing here: a
                // message the queue can never get out is otherwise stuck to the timeline for
                // good, retried on every launch, with a red badge that says so and no way to
                // answer it. This is that way. It is destructive and looks it — but what it
                // destroys is a message nobody has ever seen.
                Button(role: .destructive, action: onDiscard) {
                    Label(Strings.Message.Delivery.discard, systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.red)
            }
            .padding(.top, Theme.Spacing.tight)
        }
        .padding(Theme.Spacing.roomy)
        // A *fixed* width, not a maximum. Given a maximum, the popover measures its height
        // against the widest the text could be — one long line — and then shows it wrapped
        // into three, clipping the top and bottom off its own content. Fix the width first
        // and the height it computes is the height the text really is.
        .frame(width: Theme.Size.failurePopover, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Round video messages. A circle, masked, exactly as recorded — and played inside it.
///
/// It plays *in place* rather than opening anything: a circle is a glance, and a full-screen
/// player with a scrubber for four seconds of somebody's face is a ceremony nobody asked for.
/// Press it and it plays; press it again, or let it reach the end, and it is a still again.
private struct VideoNoteView: View {
    let attachment: Attachment

    /// How big it goes while it plays — the width of the conversation, worked out by the row
    /// around it. See `MessageRow.playingDiameter`.
    let playingDiameter: CGFloat

    @Environment(\.mediaLoader) private var loader

    @State private var playback = VideoPlayback()

    private var diameter: CGFloat {
        playback.isPlaying ? playingDiameter : Theme.Size.videoNote
    }

    var body: some View {
        Group {
            if let player = playback.player {
                VideoSurface(player: player)
            } else {
                MediaThumbnail(attachment: attachment, size: 400)
            }
        }
        // It grows while it plays and settles back when it ends. The frame is animated, not
        // a `scaleEffect`: scaling would leave the circle drawn over the messages around it
        // while the layout still believed it was 200pt wide. Growing the frame moves the
        // conversation out of its way — which is what makes the note look like it is coming
        // forward rather than sitting on top of everything.
        .frame(width: diameter, height: diameter)
        // The circle is a mask, not a background: the video underneath really is
        // square, so nothing is cropped away that the sender meant to show.
        .clipShape(.circle)
        .overlay {
            if playback.isLoading {
                ProgressView()
                    .tint(.white)
            } else if !playback.isPlaying {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.white.opacity(0.9))
                    .shadow(radius: 8)
                    // The play button gets out of the way rather than blinking out: it
                    // shrinks into the picture it was covering as that picture starts to
                    // move, and grows back out of it when the clip is over.
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .overlay(alignment: .bottom) {
            // While it plays, the clock would be counting nothing: the length is what you
            // wanted to know *before* pressing it.
            if !playback.isPlaying, let duration = attachment.duration {
                Text(Duration.seconds(duration), format: .time(pattern: .minuteSecond))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, Theme.Spacing.close)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.4), in: Capsule())
                    .padding(.bottom, Theme.Spacing.normal)
                    .transition(.opacity)
            }
        }
        // No `.animation(value:)` here. The spring lives on the change itself, in
        // `VideoPlayback` — a modifier watching `isPlaying` could not animate this, because
        // the picture inside the circle is replaced at the same moment the circle resizes,
        // and SwiftUI inserts a *different* view at its final size rather than growing the
        // old one. Animating the transaction covers the resize and the overlays with it.
        .overlay(alignment: .bottom) {
            if playback.failed {
                Text(Strings.Message.Media.loadFailed)
                    .font(.caption2)
                    .foregroundStyle(.white)
                    .padding(.horizontal, Theme.Spacing.close)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.5), in: Capsule())
                    .padding(.bottom, Theme.Spacing.normal)
            }
        }
        // One tap plays, and one tap stops. SwiftUI gives the innermost gesture the first
        // refusal, so this beats the row's double tap: a circle is played rather than
        // reacted to, and the quick reaction on one is left to the long press. That is the
        // right way round — a video message you cannot watch is worse than one you cannot
        // put an emoji on in one gesture.
        .onTapGesture { toggle() }
        // …and the same thing said in the one language a tap gesture does not speak.
        //
        // A `.onTapGesture` is invisible to VoiceOver. Not hard to reach, not badly labelled —
        // *absent*: the accessibility tree has no button here, so there was no way to play a video
        // message at all. The gesture stays for the eye and the finger; this is the same act,
        // offered to everyone else.
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { toggle() }
        .accessibilityLabel(Text(Strings.Message.Media.videoNote))
        .accessibilityHint(Text(playback.isPlaying ? Strings.Message.Media.pause
                                                   : Strings.Message.Media.play))
        // The bytes are plaintext on disk while this is on screen. Scroll the message away
        // and they go with it.
        .onDisappear { playback.stop() }
    }

    private func toggle() {
        if playback.isPlaying {
            playback.stop()
        } else {
            Task { await playback.play(attachment, using: loader, stopsAtEnd: true) }
        }
    }
}

/// A voice message: a play button, the shape of the sound, and how far through it is.
///
/// The waveform is the sender's own — computed on their device and sent with the message — so
/// both sides look at the same picture rather than each guessing at one from bytes they have
/// not downloaded. It doubles as the progress bar: the bars ahead of the playhead are faint and
/// the ones behind it are solid, which is a scrubber that takes no extra room and needs no
/// label. There is deliberately no draggable handle: this is a message, not a track, and the
/// thing people do with a voice message is listen to it from the start.
private struct VoiceMessageView: View {
    let attachment: Attachment
    let waveform: [Float]
    let isOwn: Bool

    @Environment(\.mediaLoader) private var loader

    @State private var playback = AudioPlayback()

    /// Forty bars, whatever the sender sent. A voice message is a bubble in a conversation, and
    /// a hundred-and-twenty two-point bars in one is a barcode.
    private var bars: [Float] {
        Array(waveform.prefix(40))
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.close) {
            Button {
                Task { await playback.toggle(attachment, using: loader) }
            } label: {
                Group {
                    if playback.isLoading {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                            .font(.body)
                            // The glyph swaps under the thumb that pressed it, so it swaps in
                            // place rather than blinking.
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
                .frame(width: Theme.Size.voiceButton, height: Theme.Size.voiceButton)
                .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(playback.isPlaying ? Strings.Message.Media.pause
                                                        : Strings.Message.Media.play))

            HStack(spacing: 2) {
                ForEach(Array(bars.enumerated()), id: \.offset) { index, sample in
                    Capsule()
                        .frame(width: 2, height: max(3, CGFloat(sample) * Theme.Size.waveform))
                        // Played or not. Bars are drawn in the bubble's own ink either way —
                        // faint ahead of the playhead, solid behind it — so this works on a
                        // coloured bubble and a grey one without knowing which it is in.
                        .opacity(hasPlayed(index) ? 1 : 0.35)
                }
            }
            .animation(.linear(duration: 0.05), value: playback.progress)

            if let duration = attachment.duration {
                Text(Duration.seconds(duration), format: .time(pattern: .minuteSecond))
                    .font(.caption.monospacedDigit())
            }
        }
        // The bytes are plaintext on disk while this is playing. Scroll it away and they go.
        .onDisappear { playback.stop() }
    }

    private func hasPlayed(_ index: Int) -> Bool {
        guard !bars.isEmpty else { return false }
        return Double(index) / Double(bars.count) < playback.progress
    }
}

/// A photo or a video still, sized to the shape the sender recorded.
///
/// The aspect ratio comes from the event, not from the downloaded bytes, so the bubble
/// is the right shape *before* the picture arrives and the timeline does not jump
/// around as things load.
private struct PictureBubble: View {
    let attachment: Attachment
    let isOwn: Bool
    let isPlayable: Bool

    /// Who sent it and when — carried through the bubble to the viewer, which puts them at the
    /// top of the screen. A photo opened full-screen has none of what the timeline was saying
    /// around it: no side of the conversation, no name above it, no clock beside it. See
    /// `MediaViewer`.
    let sender: String
    let timestamp: Date

    /// The photograph, once it has arrived, kept so the bubble can be made out of it. See
    /// `backdrop`.
    @State private var loaded: Image?

    /// The picture, opened. A photo and an ordinary video both come here — a circle does not,
    /// because a circle is a glance and plays where it stands.
    ///
    /// Photos used to have no tap at all: the bubble was a picture you could look at and not
    /// touch, which on a phone reads as a broken app rather than as a decision.
    @State private var isWatching = false

    private var aspectRatio: CGFloat {
        CGFloat(attachment.aspectRatio ?? 4 / 3)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            picture

            if let caption = attachment.caption {
                Text(caption)
                    .font(.body)
                    // White, because what is behind it is a darkened photograph and not the
                    // bubble fill the rest of the app writes on. `.primary` here would be
                    // black text on somebody's night sky in the light appearance, and it
                    // would be unreadable exactly half the time — which is worse than always.
                    .foregroundStyle(.white)
                    .padding(.top, Theme.Spacing.close)
                    .padding(.horizontal, Theme.Spacing.tight)
            }
        }
        .padding(Theme.Spacing.tight)
        .background { backdrop }
        .clipShape(BubbleShape())
        .pictureBorder(isOwn: isOwn)
        // The bubble, and not the rectangle around it: this is the shape a long press lifts
        // off the conversation, and it now takes in the blurred frame and the caption as well
        // as the photograph — which is the point of their being one bubble at all.
        .contentShape(BubbleShape())
        // A sheet on both platforms, and not a `fullScreenCover`: the Mac has no such thing,
        // and a picture on a Mac belongs in a window over the conversation rather than on top
        // of the entire app.
        .sheet(isPresented: $isWatching) {
            MediaViewer(attachment: attachment, isVideo: isPlayable,
                        sender: sender, timestamp: timestamp)
        }
    }

    /// The picture itself, sharp, sitting on the blur of itself. It keeps the image it fetched,
    /// which is the one `backdrop` blurs — see there.
    private var picture: some View {
        MediaThumbnail(attachment: attachment, onLoad: { loaded = $0 })
            .aspectRatio(aspectRatio, contentMode: .fit)
            .frame(maxWidth: Theme.Size.picture)
                // Half the *timeline's* height, not half the screen's: on a Mac the window
                // is what the picture has to share with the conversation, and on iPhone the
                // two are the same thing anyway.
                //
                // The height is computed rather than clamped, and it has to be: a bare
                // `maxHeight` would leave a wide photo — already shorter than the limit —
                // sitting in a tall frame with empty space above and below it. Taking the
                // smaller of the two means the frame is only ever exactly as tall as the
                // picture in it.
                .containerRelativeFrame(.vertical) { height, _ in
                    min(Theme.Size.picture / aspectRatio,
                        height * Theme.Size.pictureHeightFraction)
                }
                .overlay {
                    if isPlayable {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 40))
                            .foregroundStyle(.white.opacity(0.9))
                            .shadow(radius: 8)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if isPlayable, let duration = attachment.duration {
                        Text(Duration.seconds(duration), format: .time(pattern: .minuteSecond))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, Theme.Spacing.close)
                            .padding(.vertical, 2)
                            .background(.black.opacity(0.45), in: Capsule())
                            .padding(Theme.Spacing.close)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.picture, style: .continuous))
                .contentShape(.rect)
                .onTapGesture { isWatching = true }
                // The same act, in the language a tap gesture does not speak — see `VideoNoteView`.
                // Without this there is no way to open a photograph with VoiceOver on: the gesture
                // simply does not exist in the accessibility tree.
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { isWatching = true }
                .accessibilityLabel(Text(isPlayable ? Strings.Message.Media.video
                                                    : Strings.Message.Media.photo))
                .accessibilityHint(Text(Strings.Message.Media.openFullScreen))
    }

    /// The bubble's fill: this same photograph, blurred past reading and taken down dark.
    ///
    /// *This* photograph, and not another copy of it. It used to ask the loader for its own
    /// 64pt thumbnail, on the reasoning that a blur needs nothing bigger and the SDK is holding
    /// the bytes anyway — but the SDK's cache is keyed by size, so a second size is a second
    /// request and a second decode, and every picture in the timeline paid for two. The sharp
    /// copy above hands its image over the moment it lands (`MediaThumbnail.onLoad`), and this
    /// blurs what is already there. One fetch.
    ///
    /// Nothing at all until then: an empty bubble for the half-second before the picture
    /// arrives is what the rest of the timeline looks like anyway, and a second spinner behind
    /// the first one was never worth a round trip.
    @ViewBuilder
    private var backdrop: some View {
        if let loaded {
            loaded
                .resizable()
                .scaledToFill()
                .blur(radius: Theme.Backdrop.blur)
                // Drawn larger than the bubble and clipped back to it, so the blur's own soft
                // edges fall outside the frame — see `Theme.Backdrop.overdraw`.
                .scaleEffect(Theme.Backdrop.overdraw)
                .overlay(Color.black.opacity(Theme.Backdrop.dim))
                // It is scenery. Every press in this bubble belongs to the picture on top of it.
                .allowsHitTesting(false)
        }
    }
}
