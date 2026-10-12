import SwiftUI

/// Who gets the tap: the thing under the finger, or the message it is part of.
///
/// A conversation asks one finger to mean three things. A single tap opens the photograph, plays
/// the round video, opens the map. A double tap leaves the quick reaction, on *every* message —
/// which is what the settings screen promises. A press opens the menu. The first two are the pair
/// that cannot both simply be asked for: a double tap begins with a single one, so whichever
/// recogniser is offered the touch first wins the taps meant for the other.
///
/// Both ways round have been tried here, and both were wrong in a way somebody reported.
///
/// Innermost-first — a plain `.onTapGesture(count: 2)` on the row — gave the single tap everything:
/// a photo opened, and the promised reaction was unreachable on exactly the messages people react
/// to most. `.highPriorityGesture` inverted it, and inverting it is what broke the conversation
/// *scrolling*: a high-priority gesture outranks not only the row's own taps but the enclosing
/// scroll view's pan, so a finger that came down on a message and pulled was a finger holding the
/// timeline still. The room could be scrolled only by finding a gap between bubbles. Two bugs, one
/// dial, and no setting of it that answers both.
///
/// So the dial is abandoned. The double tap is *simultaneous* — it competes with nothing, which is
/// why the scroll view is free again and why it is heard on a photograph as readily as on a
/// sentence — and the ordering a priority was standing in for is done here, in the open: a single
/// tap on something that opens does not act at once. It waits out the interval in which a second
/// tap could still arrive, and a second tap cancels it.
///
/// That is exactly what UIKit's `require(toFail:)` does between two recognisers, done in the one
/// place where both taps are known. The cost is the quarter-second a photograph now waits before it
/// opens, which is the price of the promise being kept — and the same price the high-priority
/// version charged, for less.
///
/// The third act is the press, and it arrived here for the same reason. High priority used to
/// suppress the inner tap for free: a finger held on a photograph opened the menu, and the tap that
/// ended the hold went nowhere. Simultaneous recognition suppresses nothing, so the hold would open
/// the menu *and*, on release, the photograph behind it. `suppress()` is that fact said out loud —
/// the press announcing that the touch is spent. Every ordering this file performs is now explicit,
/// which is the point: none of it is a side effect of a priority nobody can see.
@MainActor
@Observable
final class MessageTaps {
    /// The single tap that has landed and is waiting to find out whether it was the first half of
    /// a double one.
    @ObservationIgnored private var pending: Task<Void, Never>?

    /// How long it waits. The system's own double-tap interval — a number UIKit does not publish,
    /// and a quarter of a second is what it has been for as long as there have been two taps.
    private static let interval = Duration.milliseconds(250)

    /// How long after a press the tap that ends it is refused — see `suppress`. Long enough to
    /// cover the finger coming up off a hold, short enough that the next real tap is a real tap.
    private static let suppression: TimeInterval = 0.7

    /// Until when a single tap means nothing, because a press has already spent the touch.
    @ObservationIgnored private var suppressedUntil: Date = .distantPast

    /// A tap on something that opens: the photograph, the map, the round video.
    func single(_ action: @escaping () -> Void) {
        // A press that has just opened the menu spends the whole touch, and the finger coming off
        // it is not a tap on the picture underneath — see `suppress`.
        if wasSpentByPress() { return }

        pending?.cancel()
        pending = Task { [interval = Self.interval] in
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled else { return }
            action()
        }
    }

    /// Whether the tap arriving now is only the finger coming off a press that opened the menu —
    /// and if so, it is used up: the next one is a real tap.
    ///
    /// For the taps that do not wait for a second one, and so cannot go through `single`: a link
    /// in the text, a spoiler, the quote above an answer. Each of those used to answer the hold
    /// as well as the menu did — hold a reply and the menu opened *and* the conversation jumped
    /// to the message it quoted, because a tap gesture ends on the finger lifting, however long
    /// the finger was down.
    func wasSpentByPress() -> Bool {
        guard Date.now < suppressedUntil else { return false }
        suppressedUntil = .distantPast
        return true
    }

    /// The second tap arrived; whatever the first one was about to do, it was not that.
    func double() {
        pending?.cancel()
        pending = nil
    }

    /// Nothing is left waiting behind a row that has gone.
    func cancel() {
        pending?.cancel()
        pending = nil
    }

    /// The press took the touch; the tap that ends it means nothing.
    ///
    /// A window rather than a flag, and the difference matters. A flag would be cleared by the next
    /// single tap whenever it came — so a press that opened the menu would also eat the deliberate
    /// tap made a minute later, after the menu had been dismissed, and a photograph would refuse to
    /// open exactly once for no reason anybody could see. The tap this is here to refuse arrives
    /// within milliseconds of the finger lifting; anything later is somebody asking for something.
    func suppress() {
        cancel()
        suppressedUntil = .now + Self.suppression
    }
}

extension EnvironmentValues {
    /// The arbiter for the message being drawn. Put there by `MessageActions`, read by
    /// `messageTap` below — and absent everywhere else, where a tap is only ever a tap.
    @Entry var messageTaps: MessageTaps?
}

private struct MessageTapModifier: ViewModifier {
    @Environment(\.messageTaps) private var taps
    let action: () -> Void

    func body(content: Content) -> some View {
        content.onTapGesture {
            // Outside a conversation — a photograph in the room's media grid, say — there is no
            // double tap for this to be the first half of, and nothing to wait for.
            if let taps {
                taps.single(action)
            } else {
                action()
            }
        }
    }
}

extension View {
    /// A single tap inside a message: it opens the thing under the finger, unless a second tap
    /// arrives first and turns the pair into a reaction. See `MessageTaps`.
    func messageTap(perform action: @escaping () -> Void) -> some View {
        modifier(MessageTapModifier(action: action))
    }
}
