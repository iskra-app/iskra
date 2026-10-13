import SwiftUI
import IskraCore
import IskraDesign

/// The quiet grey facts beside a message: whether it was changed after it was sent, when it
/// was sent, and — on your own — how far it has got.
///
/// One view, because both timelines say all three and would otherwise say them twice. Where
/// they go is the row's business and differs: beside the bubble in one, at the end of the line
/// in the other. What they *are* does not differ at all.
struct MessageMarks: View {
    let message: Message

    var body: some View {
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
                    .onWallpaperInk()
            }

            Text(message.timestamp, format: .dateTime.hour().minute())
                .font(.caption2.monospacedDigit())
                .onWallpaperInk()

            // A failure is not a delivery state among others, and it does not belong in
            // this quiet grey row: it gets the badge beside the message instead.
            //
            // The tick is the one thing here that is only ever drawn on your own messages, and
            // it survives into the compact column where nothing else says a message is yours.
            // That is not the layout hedging: a tick answers a question no name can — whether
            // the thing you just wrote has left the phone — and there is no other message it
            // could be asked about. A column you cannot tell your own sent messages in would be
            // a functional loss dressed up as consistency.
            //
            // It answers that question only while it is still open, mind: a message read long ago
            // draws nothing at all (see `DeliveryTick`), because the eye further down has already
            // spoken for it. What the column shows is what is outstanding, and an old message of
            // yours is not.
            if message.isOwn, let delivery = message.delivery, !delivery.hasFailed {
                DeliveryTick(status: delivery, carriesReadMark: message.carriesReadMark)
            }
        }
        // The clock must never squeeze the message it belongs to.
        .fixedSize()
    }
}
