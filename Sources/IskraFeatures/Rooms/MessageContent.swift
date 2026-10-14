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

    /// The row's tap arbiter, so a hold that opened the menu does not also open a link — see
    /// `messageText`.
    @Environment(\.messageTaps) private var taps

    /// A link the user tapped, held while they are asked whether they really mean to open it. A
    /// message can say one thing and link to another — "our shared album" pointing at a phishing
    /// page — so the address is shown in full, and nothing opens until they say so.
    ///
    /// It lives here rather than on the row, and it belongs here: it is *set* by the `openURL`
    /// override inside `messageText`, a few lines down, and the view that draws the link is the
    /// one that should hold the question about it.
    @State private var linkToConfirm: URL?

    /// The spoilers in this message somebody has tapped open, by their number in it — see
    /// `MatrixHTML` and `paintedBody`. Not kept: a spoiler scrolled away and back is hidden again,
    /// which is how Telegram's behave.
    @State private var revealedSpoilers: Set<Int> = []

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
            // Played in place, like a voice message — not handed to the system as a file.
            bubble { AudioFileView(attachment: attachment) }

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
            forwarded
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
            if message.forwardedFrom != nil || message.replyTo != nil {
                VStack(alignment: .leading, spacing: Theme.Spacing.close) {
                    forwarded
                    quote
                }
                .messageBubble(style)
            }

            inner()
        }
    }

    /// "Forwarded from Аня", over the words — Telegram's line, and for the same reason: without it
    /// the person who passed the message on reads as the person who wrote it. Only for a message
    /// that says it is a forward (`m.forwarded`); in the bubble's own ink, stepped back from it,
    /// like the quote under it.
    ///
    /// A claim, not a proof: `m.forwarded` is written by whoever sent the message, and nothing in
    /// Matrix checks it — Telegram's server vouches for its line, no homeserver does for this one.
    /// So it is drawn quietly, as the sender's own aside, and never as anything that looks verified.
    @ViewBuilder
    private var forwarded: some View {
        if let origin = message.forwardedFrom {
            Label {
                if let name = origin.displayName {
                    Text(Strings.Message.forwardedFrom(name))
                } else {
                    Text(Strings.Message.forwarded)
                }
            } icon: {
                Image(systemName: "arrowshape.turn.up.right.fill")
            }
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .opacity(0.75)
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
                // The finger coming off a hold that opened the menu is not a tap on the link it
                // happened to be resting on — see `MessageTaps.wasSpentByPress`.
                if taps?.wasSpentByPress() == true { return .handled }
                // A hidden spoiler is drawn as a link to itself, so that the tap which reveals it
                // is the text's own and not a gesture fighting the bubble's. See `paintedBody`.
                if url.scheme == Self.spoilerScheme, let number = Int(url.host() ?? "") {
                    withAnimation(.smooth(duration: Theme.Timing.reaction)) { _ = revealedSpoilers.insert(number) }
                    return .handled
                }
                // A link to a person or a room is not a page that could be pretending to be another:
                // it opens inside the app, on a page that shows who or what it is, and nothing
                // happens until a button there is pressed. Asking first would be asking twice.
                if IskraRootView.matrixLink(in: url) != nil {
                    openURL(url)
                    return .handled
                }
                linkToConfirm = url
                return .handled
            })
    }

    private func paintedBody(_ body: String) -> AttributedString {
        var attributed = RichText.attributed(body: body,
                                             formattedBody: message.formattedBody,
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

        paintFormatting(&attributed)
        return attributed
    }

    /// The scheme a hidden spoiler's tap arrives under. Never leaves this view.
    private static let spoilerScheme = "iskra-spoiler"

    /// What `MatrixHTML` marked and `Text` has no word for: underline, quotes, headings, spoilers.
    /// Bold, italic, strikethrough and code arrive as Foundation's own intents, which `Text` draws.
    private func paintFormatting(_ attributed: inout AttributedString) {
        let runs = attributed.runs.map { run in
            (run.range, run.iskra.underline ?? false, run.iskra.quote ?? false,
             run.iskra.heading, run.iskra.spoiler)
        }
        // Back to front, because a hidden spoiler's words are replaced by dots of a different
        // length — and that would move every range after it.
        for (range, underline, quote, heading, spoiler) in runs.reversed() {
            if underline {
                attributed[range].underlineStyle = .single
            }
            if quote {
                attributed[range].foregroundColor = .secondary
            }
            if let heading {
                attributed[range].font = heading <= 2 ? .title3.weight(.bold) : .headline
            }
            if let spoiler {
                if revealedSpoilers.contains(spoiler) {
                    attributed[range].backgroundColor = Color.secondary.opacity(Theme.Backdrop.wash)
                } else {
                    // Dots for the words — Telegram's speckle, in a character — so nothing of the
                    // secret is on screen until it is asked for, whatever colour links are drawn in.
                    let length = attributed[range].characters.count
                    var dots = AttributedString(String(repeating: "⠿", count: max(1, length)))
                    dots.link = URL(string: "\(Self.spoilerScheme)://\(spoiler)")
                    dots.foregroundColor = .secondary
                    attributed.replaceSubrange(range, with: dots)
                }
            }
        }
    }
}
