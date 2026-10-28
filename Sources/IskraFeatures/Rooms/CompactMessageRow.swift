import SwiftUI
import IskraCore
import IskraDesign

/// One message in the plain column: a face and a name over a run, and the messages as lines
/// under it.
///
/// The whole of what makes this different from `MessageRow` is that `isOwn` decides nothing.
/// No side of the screen, no accent fill, no marker: your messages look exactly like everybody
/// else's, and the name over the run is the only thing left saying who spoke. That is the trade
/// the reader made when they chose this — see `MessageLayout` — and it is what buys the width
/// back. The nine tenths a bubble was allowed to run to, the tenth held empty beyond it and the
/// column kept for the clock are all gone; a line takes the room it needs.
///
/// Two things follow from it, and both are forced rather than chosen:
///
/// **The name is not optional, and there is no `isOneToOne` here.** The bubble timeline drops
/// the avatar and the name in a conversation with one other person, because the side of the
/// screen is already saying who spoke and a name would be repeating it. Here nothing else says
/// it. A direct chat without names would be an anonymous column of sentences — two people
/// talking, and nothing attached to either. So this row never asks *who* — but it does ask
/// *again*: within a run the face and the name are drawn once, over the first line, and the
/// rest are indented under it.
///
/// **The clock stays on every line rather than moving into the header**, which is where the
/// shape this borrows from puts it. `TimelineMapper.runWindow` bounds the gap between *any two
/// neighbours* in a run at five minutes, not the run itself: somebody writing every four minutes
/// for an hour is one run, and a header saying 14:00 over a line sent at 15:00 would be a lie
/// told by the layout. The bubbles give every message its own time; so does this.
struct CompactMessageRow: View {
    let message: Message

    /// Everything the row can ask the conversation to do — see `MessageHandlers`.
    var handlers = MessageHandlers()

    /// The "who reacted" list a held pill has opened — see `ReactionPill.onShowReactors`.
    @State private var reactorsRequest: ReactorsRequest?

    /// Whether this message is currently pinned, which is the whole of what the menu item
    /// needs to know to say the right word.
    var isPinned: Bool = false

    /// Whether a date sits directly above this message and has already paid for the gap —
    /// see `MessageRow.opensDay`, which explains why the row stops charging for it.
    var opensDay: Bool = false

    /// Whether a message appearing here is arriving *now* — see `MessageRow.arrivesAnimated`.
    /// False unless said otherwise — see `MessageRow.arrivesAnimated`.
    var arrivesAnimated: Bool = false

    /// Whether the conversation has just jumped *to* this message, and it is briefly lit so
    /// that the eye can find it. Owned by `RoomView` — see `MessageRow.isHighlighted`.
    var isHighlighted: Bool = false

    /// The wash that lights a message the conversation has just jumped to.
    @Environment(\.accent) private var accent

    /// How wide the conversation is, measured by `RoomView` and handed down. A playing video
    /// note grows to fill it — see `EnvironmentValues.timelineWidth`.
    @Environment(\.timelineWidth) private var timelineWidth

    /// Whether this is a phone-shaped layout. A playing video note fills the width of a phone
    /// and merely doubles on a Mac or an iPad — see `playingDiameter`.
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// The face over a run, at whatever size the reader's text has grown it to — and, on every
    /// line after the first, the width of the empty column that lines them up under it. The two
    /// have to be the *same* number, which is why it is read once. See `MessageRow.avatarSize`,
    /// where getting this wrong once lined a whole run up under nothing.
    @ScaledSize(Theme.Size.avatarSmall) private var avatarSize

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
            spokenContent

            if !message.reactions.isEmpty {
                reactions
                    .padding(.leading, avatarSize + Theme.Spacing.close)
                    .transition(.reactionsAppear)
            }
        }
        // Everything is anchored to the leading edge here, your own messages included, so every
        // message gives the same way — see `SwipeToReply.dragsToward`. Around the emoji as well as
        // the line, so they go with it; outside the menu, so the copy it lifts carries no gesture.
        .swipeToReply(message, dragsToward: .trailing, onReply: handlers.onReply)
        // A run closes up and a new speaker gets air, as in the bubbles — and the first message
        // under a date takes none, because the date has already given it. See `MessageRow`. A run
        // closes up less than the bubbles' does: with no edge around a line, the gap is the only
        // thing telling two messages from one message wrapped onto two lines.
        .padding(.top, opensDay ? 0
                                : message.isContinuation ? Theme.Spacing.withinCompactRun
                                                         : Theme.Spacing.betweenSenders)
        // Lit, when the conversation has just been sent here — see `MessageRow`, which lights
        // it the same way and for the same reason.
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .fill(accent.color.opacity(isHighlighted ? 0.16 : 0))
                .padding(.horizontal, -Theme.Spacing.close)
                .allowsHitTesting(false)
        }
        .animation(.smooth(duration: Theme.Timing.reaction * 2), value: isHighlighted)
        // The emoji, which change the row's height — see `MessageRow`.
        .animation(.smooth(duration: Theme.Timing.reaction), value: message.reactions.map(\.key))
        // And nothing else — a message that is only *changing* changes at once, here exactly as
        // in the bubbles, and the arrival is the row's own. See `MessageRow`, where the reasoning
        // is written out, and `MessageArrival`.
        // Every line starts at the leading edge here, yours included, so nothing has anywhere to
        // travel *to*: a line of ours simply comes up into its place without fading, as it would in
        // the bubbles, and somebody else's fades up into it.
        .arrives(arrivesAnimated, outgoing: message.isOwn)
    }

    /// The face over a run, and an empty column of exactly its width under it.
    ///
    /// Only the first message of a run carries the avatar — the same rule as `MessageRow`, and
    /// for the same reason: a face repeated down five consecutive lines from one person says
    /// nothing the first one did not, and it turns a run into five separate arrivals. The lines
    /// after it are indented by `avatarSize` so the run still starts on one column.
    ///
    /// What does *not* follow the bubbles is dropping it in a direct chat. There is no
    /// `isOneToOne` here, because nothing else in this row says who spoke.
    @ViewBuilder
    private var avatarColumn: some View {
        if message.isContinuation {
            Color.clear.frame(width: avatarSize)
        } else {
            Avatar(name: message.senderName, url: message.senderAvatarURL,
                   size: Theme.Size.avatarSmall, seed: message.senderID)
        }
    }

    /// The face, the name and the line — everything a long press lifts.
    ///
    /// Here, unlike in the bubbles, the menu takes the whole row and not only the words. A bubble
    /// is a shape that says who spoke by which side it stands on; a plain line lifted on its own
    /// was a sentence floating over the darkened room with nothing to say whose it was or when.
    /// Without the face, the name and the clock, the compact layout has nothing else to say it.
    /// The emoji stay behind, as they do under a bubble: the menu draws its own.
    private var heading: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.close) {
            avatarColumn

            VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                if !message.isContinuation {
                    Text(message.senderName)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }

                line
            }

            Spacer(minLength: 0)
        }
        .modifier(LiftedCard())
    }

    /// The message itself, and the grey facts at the end of it.
    ///
    /// `.top`, and not a baseline: the fourteen kinds are not all made of text, and a clock
    /// asked to sit on the baseline of a photograph drops to the bottom of it — a tall picture
    /// would leave its time stranded a screen below the line it belongs to. The top of the
    /// message is a place every kind has.
    ///
    /// The marks are pushed to the far edge rather than left beside the words, so the times make
    /// a quiet column down the side instead of a ragged edge that moves with every sentence.
    private var line: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
            lineContent
            if let thread = message.thread, let open = handlers.onOpenThread {
                ThreadLine(thread: thread, onOpen: open)
            }
        }
    }

    private var lineContent: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.close) {
            MessageContent(message: message,
                           style: .plain,
                           playingDiameter: playingDiameter,
                           onOpenReply: handlers.onOpenReply,
                       onVote: handlers.onVote)
                .uploadProgress(of: message, onCancel: handlers.onDiscard)

            Spacer(minLength: 0)

            // The alarm goes next to the clock rather than in front of the words. Leading it
            // would push the line in from the column every other line starts on, which is the
            // one thing this layout guarantees.
            if case let .failed(failure)? = message.delivery {
                SendFailureBadge(failure: failure,
                                 onRetry: handlers.onRetry,
                                 onSendAnyway: handlers.onSendAnyway,
                                 onDiscard: handlers.onDiscard)
            }

            MessageMarks(message: message)
        }
    }

    /// One sentence for VoiceOver, unless there is a button inside the message that flattening
    /// would swallow — the same rule, and the same reason, as `MessageRow.bubbleRow`.
    ///
    /// VoiceOver has no runs: it reads a line at a time, and a reader who cannot see the face
    /// above a run has nothing to carry the name down it. `spokenLabel` names the sender on
    /// every message, which is exactly what a linear reader needs and is unchanged from the
    /// bubbles.
    @ViewBuilder
    private var spokenContent: some View {
        let content = heading
            .messageActions(message, isPinned: isPinned, handlers: handlers)

        if message.hasPressableContent {
            content.accessibilityElement(children: .contain)
        } else {
            content
                .accessibilityElement(children: .combine)
                .accessibilityLabel(message.spokenLabel)
        }
    }

    /// The emoji under a message, lined up with the words rather than with the face beside them.
    ///
    /// No inset of its own and no climbing back onto anything: the avatar column indents these
    /// structurally, and there is no bubble whose bottom edge they could tuck under. Both the
    /// `leadingInset` arithmetic and the `reactionOverlap` the bubbles need are simply absent.
    private var reactions: some View {
        FlowLayout(spacing: Theme.Spacing.tight, alignment: .leading) {
            ForEach(message.reactions) { reaction in
                ReactionPill(reaction: reaction,
                             onShowReactors: handlers.loadReactors == nil ? nil : {
                                 reactorsRequest = ReactorsRequest(filter: reaction.key)
                             }) {
                    handlers.onToggleReaction(reaction.key)
                }
                .transition(.scale(scale: 0.3).combined(with: .opacity))
            }
        }
        .reactorsSheet($reactorsRequest, reactions: message.reactions, load: handlers.loadReactors,
                       loadReaders: handlers.loadReaders)
    }

    /// How big a video note goes while it plays.
    ///
    /// The same arithmetic as `MessageRow.playingDiameter`, one term shorter: nothing stands
    /// beside a message here, so the circle has the width less the avatar's column. The avatar
    /// column is always there, which is what makes this simpler than the bubble's version — it
    /// has to ask whether a name is being shown at all.
    private var playingDiameter: CGFloat {
        let available = timelineWidth - avatarSize - Theme.Spacing.close

        let wanted = horizontalSizeClass == .compact
            ? available
            : min(available, Theme.Size.videoNote * Theme.Size.videoNoteGrowth)

        return max(Theme.Size.videoNote, wanted)
    }
}

/// The page under a compact row while it is up in the message menu — see `bubbleIsLifted`.
///
/// A plain row has no fill of its own, and over the menu's curtain its grey name and clock were
/// grey on grey. Lifted, it carries a card of the page with it, so it reads as it did in the
/// conversation; in the conversation it carries nothing.
private struct LiftedCard: ViewModifier {
    @Environment(\.bubbleIsLifted) private var isLifted

    func body(content: Content) -> some View {
        // Drawn out past the row rather than padding it: the menu puts the copy exactly where the
        // row stood, and a row grown by its own margin would land beside itself.
        content.background {
            if isLifted {
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .fill(Color.page)
                    .padding(-Theme.Spacing.close)
            }
        }
    }
}

/// Somebody writing, in the plain column: the dots where a face would be, and who it is beside them
/// in the same small grey the names over a run are set in.
///
/// Not the bubble. The compact timeline has no bubbles, and one appearing at its foot would be
/// the only shape of its kind in the whole column — a piece of the other layout left behind. And
/// it names people, even in a chat with one other person, for the reason `CompactMessageRow`
/// always names the sender: nothing else in this column says who.
struct CompactTypingRow: View {
    let names: [String]

    @ScaledSize(Theme.Size.avatarSmall) private var avatarSize

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.close) {
            TypingDots(dot: Theme.Spacing.tight, spacing: Theme.Spacing.tight)
                .frame(width: avatarSize)

            // The last names that were typing, held while the row fades — an empty sentence for
            // the length of the fade would be worse than a slightly stale one.
            Text(names.isEmpty ? "" : String(app: Strings.Room.typingBy(names.formatted(.list(type: .and)))))
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .padding(.top, Theme.Spacing.betweenSenders)
        .accessibilityHidden(true)
    }
}
