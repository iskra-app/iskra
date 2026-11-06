import SwiftUI
import IskraDesign

/// The second answer to a question: the same capsule as `AnswerStyle`, the same height and type,
/// but filled with a neutral and with only the words in red.
///
/// Two saturated pills side by side, green and red, made an invitation row the loudest thing in
/// the chat list. "Join" stays the one filled action; "Decline" is a refusal people may want and
/// should not be tempted into, so it sits quietly beside it.
struct QuietAnswerStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Face(configuration: configuration)
    }

    private struct Face: View {
        let configuration: Configuration
        @ScaledSize(Theme.Size.minimumTapTarget) private var height
        @Environment(\.design) private var design

        /// The calm look keeps "no" in its own coral, the pair to the lime "yes".
        private var isCalm: Bool { design == .calm }

        var body: some View {
            configuration.label
                .font(.subheadline.weight(.semibold))
                // The same deep red `AnswerStyle` fills with, which holds 4.5:1 as text on the
                // neutral fill in both appearances far better than the system red does.
                .foregroundStyle(isCalm ? Theme.Calm.onAccent : Color(red: 0.77, green: 0.15, blue: 0.11))
                .lineLimit(1)
                .padding(.horizontal, Theme.Spacing.normal)
                .padding(.vertical, Theme.Spacing.tight)
                .background(isCalm ? AnyShapeStyle(Theme.Calm.trash) : AnyShapeStyle(.fill.tertiary), in: .capsule)
                .opacity(configuration.isPressed ? 0.6 : 1)
                .frame(minHeight: height)
                .contentShape(.rect)
        }
    }
}

extension ButtonStyle where Self == QuietAnswerStyle {
    static var quietAnswer: QuietAnswerStyle { QuietAnswerStyle() }
}
