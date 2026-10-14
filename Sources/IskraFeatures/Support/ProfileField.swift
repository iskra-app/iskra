import SwiftUI
import IskraDesign

/// One fact on a profile, Telegram's way: a small label on top, the thing itself underneath.
///
/// Not `LabeledContent`, which puts the two side by side — fine for "Notifications: All", and
/// wrong for a Matrix ID, which was cut in the middle to fit beside its own label, or a room's
/// description, which is a paragraph and had to sit in a section of its own to have the room.
struct ProfileField<Value: View>: View {
    let title: LocalizedStringResource
    @ViewBuilder let value: Value

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
            Text(title)
                .font(.subheadline)
            value
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, Theme.Spacing.tight)
    }
}

/// A person's Matrix ID on their page: in the accent, which is how Telegram marks the one line on a
/// profile that is an address rather than a description, with a copy button beside it — the ID is
/// the thing people open this page to take away, and a long press to select it is a gesture
/// nobody guesses.
///
/// The mono accent is `.primary`, so there it is simply the colour of text.
struct MatrixIDField: View {
    let userID: String

    @Environment(\.accent) private var accent

    /// The tick that replaces the icon for a moment, so a copy that changes nothing on screen is
    /// not a copy the reader has to take on trust.
    @State private var didCopy = false

    var body: some View {
        HStack(spacing: Theme.Spacing.normal) {
            ProfileField(title: Strings.Profile.matrixID) {
                Text(verbatim: userID)
                    .foregroundStyle(accent.color)
                    .textSelection(.enabled)
            }

            Button {
                Clipboard.copy(userID)
                didCopy = true
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    didCopy = false
                }
            } label: {
                Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                    .font(.title3)
                    .foregroundStyle(accent.color)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Text(Strings.Message.Menu.copy))
        }
    }
}
