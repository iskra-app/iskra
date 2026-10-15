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
/// **There is no close button, no swipe to dismiss, and no "Skip".** The code is shown exactly once
/// and can never be shown again — that is a property of how the secret is stored, not a decision
/// anybody made about this screen — so a code dismissed by reflex is a code the user does not have,
/// and they find that out months later, from a screen that cannot help them.
///
/// "Skip" used to be the way out, on the grounds that a modal with no exit is one people learn to
/// dismiss without reading, and the room-list banner would nag afterwards. It is gone, and what
/// replaces it is not simply its absence: the one remaining button is *inert until the user says
/// they have written the code down*. That is the difference between a screen you leave by tapping
/// the only thing on it and a screen you leave by making a claim. A tap is a reflex; a tick is an
/// answer, and it is the last honest moment to notice you have not actually saved anything.
struct RecoveryCodeView: View {
    let code: String

    var onSaved: () -> Void

    /// Local, because nobody outside this view reads it. SwiftUI rebuilds the content on each
    /// presentation, so it starts out false without anybody resetting it.
    @State private var hasCopied = false

    /// The claim. Nothing checks it and nothing can — there is nowhere to look — so it is not a
    /// verification, it is a moment of attention, which is the only thing this screen can actually
    /// buy. It is worth the tick: the way people lose a recovery code is not by deciding not to save
    /// it, it is by tapping past the screen that was offering it to them.
    @State private var hasWrittenItDown = false

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

            warning

            Button {
                copy()
            } label: {
                Label(String(app: hasCopied ? Strings.Encryption.keyCopied : Strings.Encryption.copyKey),
                      systemImage: hasCopied ? "checkmark" : "doc.on.doc")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassSecondary)

            // The tick, and then the way out. In this order, because the button is the consequence of
            // the tick and not a thing sitting beside it.
            Toggle(isOn: $hasWrittenItDown) {
                Text(Strings.Recovery.saveConfirm)
                    .font(.callout)
            }
            .toggleStyle(.switch)
            .accentControl()
            .padding(.horizontal, Theme.Spacing.close)

            Button(action: onSaved) {
                Text(Strings.Encryption.saved)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassAction)
            .controlSize(.large)
            .frame(maxWidth: .infinity)
            .disabled(!hasWrittenItDown)
        }
        .animation(.smooth, value: hasWrittenItDown)
        .padding(Theme.Spacing.generous)
        .frame(maxWidth: Theme.Size.keySheet)
        .interactiveDismissDisabled()
    }

    /// What is actually at stake, said once, in the plainest words there are.
    ///
    /// It is not a repeat of the help text above, which explains what the code *is*. This says what
    /// happens if it is lost, and it says the part people do not believe until it is too late: that
    /// nobody can help — not the server, not the people you talk to, not us. An app that only says
    /// "keep this safe" is asking to be trusted about how serious it is. This one gives the reason,
    /// and lets the reader be as alarmed as the situation deserves.
    private var warning: some View {
        Label {
            Text(Strings.Recovery.saveWarning)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .font(.footnote)
        .foregroundStyle(.orange)
        .multilineTextAlignment(.leading)
        .padding(Theme.Spacing.normal)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(Theme.Backdrop.wash),
                    in: .rect(cornerRadius: Theme.Radius.control, style: .continuous))
    }

    private func copy() {
        // The *secret* path, not the ordinary one. See `Clipboard.copySecret`: this string is the
        // password to every message the account has ever received, and the general pasteboard syncs
        // to every other device on the Apple ID and keeps what it is given indefinitely.
        Clipboard.copySecret(code)
        hasCopied = true
    }
}
