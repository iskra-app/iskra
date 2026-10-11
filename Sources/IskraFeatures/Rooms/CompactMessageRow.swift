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

    /// Whether this message is currently pinned, which is the whole of what the menu item
    /// needs to know to say the right word.
    var isPinned: Bool = false

    /// Whether a date sits directly above this message and has already paid for the gap —
    /// see `MessageRow.opensDay`, which explains why the row stops charging for it.
    var opensDay: Bool = false

    /// Whether a message appearing here is arriving *now* — see `MessageRow.arrivesAnimated`.
    var arrivesAnimated: Bool = true

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
        HStack(alignment: .top, spacing: Theme.Spacing.close) {
            avatarColumn

            VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                if !message.isContinuation {
                    Text(message.senderName)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }

                line

                if !message.reactions.isEmpty {
                    reactions
                        .transition(.reactionsAppear)
                }
            }

            Spacer(minLength: 0)
        }
        // A run closes up and a new speaker gets air, exactly as in the bubbles — and the first
        // message under a date takes none, because the date has already given it. See `MessageRow`.
        .padding(.top, opensDay ? 0
                                : message.isContinuation ? Theme.Spacing.withinRun
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
        .arrives(arrivesAnimated)
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
        HStack(alignment: .top, spacing: Theme.Spacing.close) {
            spokenContent

            Spacer(minLength: 0)

            // The alarm goes next to the clock rather than in front of the words. Leading it
            // would push the line in from the column every other line starts on, which is the
            // one thing this layout guarantees.
            if case let .failed(failure)? = message.delivery {
                SendFailureBadge(failure: failure,
                                 onRetry: handlers.onRetry,
                                 onDiscard: handlers.onDiscard)
            }

            MessageMarks(message: message)
        }
        // Everything is anchored to the leading edge here, your own messages included, so every
        // message gives the same way — see `SwipeToReply.dragsToward`.
        .swipeToReply(message, dragsToward: .trailing, onReply: handlers.onReply)
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
        let content = MessageContent(message: message,
                                     style: .plain,
                                     playingDiameter: playingDiameter,
                                     onOpenReply: handlers.onOpenReply)
            .uploadProgress(of: message, onCancel: handlers.onDiscard)
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
                ReactionPill(reaction: reaction) {
                    handlers.onToggleReaction(reaction.key)
                }
                .transition(.scale(scale: 0.3).combined(with: .opacity))
            }
        }
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
