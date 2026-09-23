import SwiftUI
import IskraCore
import IskraDesign

/// What is *in* a message: the fourteen kinds, dressed in whatever the row asked for.
///
/// It knows what to draw and nothing about where. The row above decides the geometry and hands
/// down the two facts this needs — how a message is dressed, and how big a video note may grow
/// — and that is the whole seam between the two timelines: `MessageRow` and `CompactMessageRow`
/// draw completely different rows around exactly this, unchanged.
///
/// There is no branch here on which timeline is running, and that is the point. The wrapper
/// learned a third answer instead — `BubbleStyle.plain` draws no fill and spends no padding, so
/// it is the identity — and fourteen cases that would otherwise each need an opinion about the
/// compact layout get to keep not having one.
struct MessageContent: View {
    let message: Message

    /// A bubble in the sender's colour, a grey one, or nothing at all. See `BubbleStyle`.
    let style: BubbleStyle

    /// How big a video note goes while it plays — the row's arithmetic, because only the row
    /// knows what else is standing beside it.
    let playingDiameter: CGFloat

    /// Goes to the message this one is answering. Pressed on the quote; only `RoomView` can
    /// actually scroll the conversation, so it is reported upward.
    let onOpenReply: (String) -> Void

    @Environment(\.accent) private var accent

    /// The real opener, captured before the message text overrides `openURL` to intercept taps.
    /// The confirmation's "Open" hands the URL back to this.
    @Environment(\.openURL) private var openURL

    /// Who *you* are, for telling a mention of you from a mention of anyone else — see `paintedBody`.
    @Environment(\.currentUserID) private var currentUserID
    @Environment(\.currentUserName) private var currentUserName

    /// A link the user tapped, held while they are asked whether they really mean to open it. A
    /// message can say one thing and link to another — "our shared album" pointing at a phishing
    /// page — so the address is shown in full, and nothing opens until they say so.
    ///
    /// It lives here rather than on the row, and it belongs here: it is *set* by the `openURL`
    /// override inside `messageText`, a few lines down, and the view that draws the link is the
    /// one that should hold the question about it.
    @State private var linkToConfirm: URL?

    /// Which way a stack of things — a quote and the picture under it — lines up. Read off the
    /// style rather than off `isOwn`, which comes to the same thing and says why: only a message
    /// dressed as the reader's own is anchored to the far edge. Grey ones and plain ones both
    /// start at the leading edge.
    private var alignment: HorizontalAlignment {
        style == .own ? .trailing : .leading
    }

    var body: some View {
        content
            // Where a tapped link really goes, shown in full before anything opens. The title carries
            // the address itself — the one thing the message text can lie about — so the choice is
            // made against the destination, not the words dressed over it.
            .confirmationDialog(Text(verbatim: linkToConfirm?.absoluteString ?? ""),
                                isPresented: Binding(get: { linkToConfirm != nil },
                                                     set: { if !$0 { linkToConfirm = nil } }),
                                titleVisibility: .visible,
                                presenting: linkToConfirm) { url in
                Button(String(app: Strings.Message.Link.open)) {
                    openURL(url)
                    linkToConfirm = nil
                }
                Button(String(app: Strings.Message.Link.cancel), role: .cancel) {
                    linkToConfirm = nil
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch message.kind {
        case let .text(body):
            bubble { messageText(body) }

        case let .notice(body):
            bubble { messageText(body).italic() }

        case let .emote(body):
            quoted {
                messageText(body)
                    .font(.callout.italic())
                    .foregroundStyle(.secondary)
            }

        case let .videoNote(attachment):
            // The signature shape: a circle, not a bubble. No bubble background, so
            // no rounded-rectangle peeking out behind the mask.
            quoted {
                VideoNoteView(attachment: attachment, playingDiameter: playingDiameter)
            }

        case let .voice(attachment, waveform):
            bubble { VoiceMessageView(attachment: attachment, waveform: waveform) }

        case let .image(attachment):
            quoted {
                PictureBubble(attachment: attachment, messageID: message.id,
                              style: style, isPlayable: false,
                              sender: message.spokenSender, timestamp: message.timestamp)
            }

        case let .sticker(attachment):
            // No bubble, and nothing to open. A sticker is already the shape its sender drew,
            // and the transparency around it is most of what makes it one — put it on a fill
            // and it becomes a small photograph of a sticker.
            quoted {
                StickerView(attachment: attachment)
            }

        case let .video(attachment):
            quoted {
                PictureBubble(attachment: attachment, messageID: message.id,
                              style: style, isPlayable: true,
                              sender: message.spokenSender, timestamp: message.timestamp)
            }

        // `quoted`, like every other kind that draws its own bubble rather than sitting in
        // one. These two were bare, and the quote above an answer to a file or a piece of
        // music was silently dropped.
        case let .audio(attachment):
            quoted {
                FileBubble(attachment: attachment, systemImage: "waveform", style: style)
            }

        case let .file(attachment):
            quoted {
                FileBubble(attachment: attachment, systemImage: "doc", style: style)
            }

        case let .location(location):
            quoted {
                LocationBubble(location: location, style: style)
            }

        case .unreadable:
            // Not an error the user caused, and not one they can fix. Say what
            // happened without the word "decrypt".
            bubble {
                Label { Text(Strings.Message.unreadable) } icon: { Image(systemName: "lock.slash") }
                    .font(.footnote)
            }

        case .deleted:
            // Not `bubble`: a message that is gone is drawn as an outline with nothing in it,
            // and in the plain column as nothing but its words — see `deletedBubble`, which is
            // where the difference is argued.
            Text(Strings.Message.deleted)
                .font(.footnote.italic())
                .deletedBubble(style)

        case .unsupported:
            bubble {
                Text(Strings.Message.unsupported)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
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
        .messageBubble(style)
    }

    /// The same quote for the messages that have no bubble to put it in — a photo, a circle, an
    /// emote. It gets a small bubble of its own and sits above them.
    private func quoted(@ViewBuilder _ inner: () -> some View) -> some View {
        VStack(alignment: alignment, spacing: Theme.Spacing.tight) {
            if message.replyTo != nil {
                quote
                    .messageBubble(style)
            }

            inner()
        }
    }

    @ViewBuilder
    private var quote: some View {
        if let reply = message.replyTo {
            ReplyQuote(reply: reply, style: style) {
                onOpenReply(reply.eventID)
            }
        }
    }

    /// A message's words, with the links in them live but held, and the mentions in them painted.
    /// `RichText` (in Core) marks where the links and mentions are; the colour goes on here, because
    /// colour is a thing the design layer owns and the model layer cannot see. A mention of you is
    /// drawn louder than a mention of someone else — it is the one that means *you* were called.
    /// Overriding `openURL` is what turns a tapped link into a question instead of a jump.
    private func messageText(_ body: String) -> some View {
        Text(paintedBody(body))
            .tint(accent.color)
            .environment(\.openURL, OpenURLAction { url in
                linkToConfirm = url
                return .handled
            })
    }

    private func paintedBody(_ body: String) -> AttributedString {
        var attributed = RichText.attributed(body: body,
                                             mentionedUserIDs: Set(message.mentionedUserIDs),
                                             displayNames: currentUserID.isEmpty ? [:] : [currentUserID: currentUserName],
                                             ownUserID: currentUserID.isEmpty ? nil : currentUserID)

        // Collect first, then paint: mutating the attributed string invalidates the run indices you
        // are iterating.
        let mentionRuns = attributed.runs.compactMap { run -> (Range<AttributedString.Index>, Bool)? in
            guard run.iskra.mentionUserID != nil else { return nil }
            return (run.range, run.iskra.mentionIsSelf ?? false)
        }
        // Links underlined, as well as tinted. Colour alone is a promise the reader has to know the
        // code for — and in a bubble already filled with the accent, the tinted words were very
        // nearly the colour of the bubble around them.
        let linkRanges = attributed.runs.compactMap { run in run.link == nil ? nil : run.range }
        for range in linkRanges {
            attributed[range].underlineStyle = .single
        }

        for (range, isSelf) in mentionRuns {
            attributed[range].foregroundColor = accent.color
            if isSelf {
                // Your own name gets weight and a wash behind it — the "you were mentioned" that the
                // red badge in the list is the far-off twin of.
                attributed[range].font = .body.weight(.semibold)
                attributed[range].backgroundColor = accent.color.opacity(0.16)
            }
        }
        return attributed
    }
}
