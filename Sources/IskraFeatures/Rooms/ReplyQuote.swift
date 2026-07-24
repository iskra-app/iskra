import SwiftUI
import IskraCore
import IskraDesign

/// The message being answered, drawn small: a bar, a name, and one line of what they said.
///
/// It appears in two places and is deliberately one view, because they are the same object at
/// two moments in its life — the quote you are *about to* send, sitting above the composer, and
/// the quote you *did* send, sitting inside the bubble. Two views would drift, and the user
/// would compose against one thing and post another.
///
/// It carries no colour of its own. Inside your own bubble the words are white on the accent;
/// inside somebody else's they are the app's usual ink on grey — and the quote has to be
/// legible in both without knowing which it is in. So it does not choose a colour: it takes
/// whatever foreground the bubble around it set, and steps back from it with opacity. That is
/// the one styling rule here, and it is what lets the same view live in both places.
struct ReplyQuote: View {
    let reply: ReplyPreview

    /// What the bubble it is sitting in is dressed in, which decides only one thing: how hard
    /// the accent bar down the side is allowed to shout. On a coloured bubble it is drawn out of
    /// the bubble's own ink; on a grey one — and on no bubble at all — it is the app's accent,
    /// which is the only splash of colour a quote gets and the thing that makes it read as a
    /// quote at a glance.
    ///
    /// `.plain` falls on the same side as `.incoming` by construction, and that is right rather
    /// than lucky: the ink there is the ordinary one, so the bar has to bring its own colour.
    /// In the compact timeline this is very nearly the only work the accent has left.
    var style: BubbleStyle = .incoming

    /// Goes to the message being quoted. Nil where there is nowhere to go — the composer's
    /// strip quotes a message that is already on the screen behind it.
    var onOpen: (() -> Void)?

    @Environment(\.accent) private var accent

    var body: some View {
        HStack(spacing: Theme.Spacing.close) {
            // The bar is what says "this is somebody else's words, quoted" — the oldest
            // typographic convention there is, and it survives being three points wide.
            Capsule()
                .fill(style == .own ? AnyShapeStyle(.foreground.opacity(0.5))
                                    : AnyShapeStyle(accent.color))
                .frame(width: Theme.Size.quoteBar)

            VStack(alignment: .leading, spacing: 0) {
                if let name = reply.senderName {
                    Text(name)
                        .font(.caption.weight(.semibold))
                }

                Text(reply.text)
                    .font(.caption)
                    .lineLimit(1)
                    // A step back from whatever ink the bubble is using, rather than a colour
                    // of its own. See the note above the view.
                    .opacity(0.75)
            }

            Spacer(minLength: 0)
        }
        // Tall enough to read, short enough that quoting a paragraph does not make the answer
        // taller than the thing it answers.
        .frame(maxWidth: Theme.Size.quote, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .contentShape(.rect)
        .onTapGesture { onOpen?() }
        .accessibilityElement(children: .combine)
        // Not a literal the linter should catch: every word here is already localised — the label
        // is `String(app:)` and the quoted line is the message's own text. What is between them is
        // punctuation, not a sentence to translate.
        // swiftlint:disable:next literal_string_in_view
        .accessibilityLabel(Text("\(String(app: Strings.Room.replyingTo)): \(reply.text)"))
    }
}
