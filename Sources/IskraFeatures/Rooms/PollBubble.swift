import SwiftUI
import IskraCore
import IskraDesign

/// A poll in the conversation: the question, the answers, and — once there is something to show —
/// how the room answered.
///
/// One tap votes. There is no "Vote" button under the answers, because a poll response replaces the
/// one before it, so a mis-tap costs nothing: tap the other answer. In a multiple-choice poll a tap
/// ticks or unticks, and each tick goes out as it is made.
///
/// The bars stay hidden until you have answered, then appear (`Poll.showsResults`) — seeing which
/// way the room leans before choosing is exactly what a poll's sender does not want.
struct PollBubble: View {
    let poll: Poll
    let style: BubbleStyle
    let onVote: ([String]) -> Void

    @Environment(\.accent) private var accent

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.normal) {
            VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                Text(header)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(verbatim: poll.question)
                    .font(.body.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: Theme.Spacing.normal) {
                ForEach(poll.answers) { answer in
                    row(answer)
                }
            }

            Text(footer)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(width: Theme.Size.poll, alignment: .leading)
        .animation(.smooth(duration: 0.3), value: poll)
    }

    private var header: String {
        var words = [String(app: poll.isEnded ? Strings.Poll.ended
                                : poll.isDisclosed ? Strings.Poll.kind : Strings.Poll.kindAnonymous)]
        if poll.isMultipleChoice && !poll.isEnded { words.append(String(app: Strings.Poll.multiple)) }
        return words.joined(separator: " · ")
    }

    private var footer: String {
        guard poll.voters > 0 else { return String(app: Strings.Poll.noVotes) }
        let count = String(app: Strings.Poll.voters(poll.voters))
        return poll.showsResults ? count : "\(count) · \(String(app: Strings.Poll.hiddenUntilEnd))"
    }

    private func row(_ answer: Poll.Answer) -> some View {
        Button {
            if let choice = poll.choice(afterTapping: answer.id) { onVote(choice) }
        } label: {
            VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.close) {
                    marker(answer)
                    Text(verbatim: answer.text)
                        .font(answer.isWinner ? .body.weight(.semibold) : .body)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if poll.showsResults {
                        Text(poll.share(of: answer), format: .percent.precision(.fractionLength(0)))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                if poll.showsResults {
                    bar(poll.share(of: answer))
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(poll.isEnded)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: answer.text))
        .accessibilityValue(spokenValue(answer))
        .accessibilityAddTraits(answer.isChosen ? .isSelected : [])
    }

    /// A circle for one answer, a square for several — the system's own convention for the two.
    /// Filled with a tick when it is yours.
    @ViewBuilder
    private func marker(_ answer: Poll.Answer) -> some View {
        let shape = poll.isMultipleChoice ? "square" : "circle"
        Image(systemName: answer.isChosen ? "checkmark.\(shape).fill" : shape)
            .font(.body)
            .foregroundStyle(answer.isChosen ? fill : AnyShapeStyle(.secondary))
            .opacity(poll.isEnded && !answer.isChosen ? 0 : 1)
    }

    private func bar(_ share: Double) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(fill)
                    .frame(width: max(Theme.Size.pollBar, proxy.size.width * share))
                    .opacity(share > 0 ? 1 : 0)
            }
        }
        .frame(height: Theme.Size.pollBar)
    }

    /// On your own bubble the accent is already the background, so the bars take the ink.
    private var fill: AnyShapeStyle {
        style == .own ? AnyShapeStyle(.primary) : AnyShapeStyle(accent.color)
    }

    private func spokenValue(_ answer: Poll.Answer) -> Text {
        var parts: [String] = []
        if answer.isChosen { parts.append(String(app: Strings.Poll.chosen)) }
        if poll.showsResults {
            parts.append(poll.share(of: answer).formatted(.percent.precision(.fractionLength(0))))
        }
        return Text(verbatim: parts.joined(separator: ", "))
    }
}
