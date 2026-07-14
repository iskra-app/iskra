import SwiftUI
import IskraCore
import IskraDesign

/// The recovery code, the once.
///
/// It used to be `KeySheet`, private to the encryption screen, back when settings was the only place
/// a code could be made. It is here now because there are three such places — a new account, a fresh
/// start, and the settings screen — and a code that is presented three different ways is a code that
/// is explained three different ways.
///
/// **There is no close button and no swipe to dismiss.** That is not an interaction pattern anyone
/// enjoys and it is the correct one: the code is shown exactly once and can never be shown again —
/// that is a property of how the secret is stored, not a decision anybody made about this screen —
/// so a code swiped away by reflex is a code the user does not have. They find that out months later,
/// from a screen that cannot help them. The only ways out are the two buttons, and both of them are
/// answers.
struct RecoveryCodeView: View {
    let code: String

    var onSaved: () -> Void

    /// Offered where skipping is allowed — during setup, where the design note explicitly permits it,
    /// and where the room-list banner will keep asking afterwards. `nil` in settings, where the user
    /// went out of their way to mint this code and there is nothing to nag them with.
    var onSkip: (() -> Void)?

    /// Local, because nobody outside this view reads it. SwiftUI rebuilds the content on each
    /// presentation, so it starts out false without anybody resetting it.
    @State private var hasCopied = false

    var body: some View {
        VStack(spacing: Theme.Spacing.roomy) {
            Image(systemName: "key.horizontal.fill")
                .font(.largeTitle)
                .foregroundStyle(.orange)

            Text(Strings.Encryption.saveKey)
                .font(.title2.weight(.semibold))

            Text(Strings.Encryption.saveKeyHelp)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            // Monospaced and selectable: this is a string somebody is going to compare character by
            // character one day, in a bad mood.
            Text(code)
                .font(.body.monospaced())
                .textSelection(.enabled)
                .multilineTextAlignment(.center)
                .padding(Theme.Spacing.roomy)
                .frame(maxWidth: .infinity)
                .background(.fill.tertiary, in: .rect(cornerRadius: Theme.Radius.card, style: .continuous))

            // The same two glasses as the sign-in screen, and for the same reason `CLAUDE.md` gives:
            // this is the navigation layer — getting into the app — and the tinted one is spent on
            // the single action the screen is about. It was `.bordered` over `.primaryAction`, which
            // is the *content* pairing, so the last screen of the way in was drawn in the manners of
            // a settings row.
            Button {
                copy()
            } label: {
                Label(String(app: hasCopied ? Strings.Encryption.keyCopied : Strings.Encryption.copyKey),
                      systemImage: hasCopied ? "checkmark" : "doc.on.doc")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
            .controlSize(.large)

            Button(action: onSaved) {
                Text(Strings.Encryption.saved)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassAction)
            .controlSize(.large)
            .frame(maxWidth: .infinity)

            if let onSkip {
                Button(action: onSkip) {
                    Text(Strings.Recovery.skip)
                        // `.footnote`, which is what every quiet way-out in this flow and on the
                        // sign-in screen is set in. And still 44pt tall: a `.plain` button is exactly
                        // as tall as its words, about 20pt, against the 44 Apple asks for. Quiet is a
                        // matter of size and colour, not of being hard to hit.
                        .font(.footnote)
                        .frame(maxWidth: .infinity, minHeight: Theme.Size.minimumTapTarget)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(Theme.Spacing.generous)
        .frame(maxWidth: Theme.Size.keySheet)
        .interactiveDismissDisabled()
    }

    private func copy() {
        // The *secret* path, not the ordinary one. See `Clipboard.copySecret`: this string is the
        // password to every message the account has ever received, and the general pasteboard syncs
        // to every other device on the Apple ID and keeps what it is given indefinitely.
        Clipboard.copySecret(code)
        hasCopied = true
    }
}
