import SwiftUI
import IskraCore
import IskraDesign

/// The strip across the top of the chat list that will not let the user forget.
///
/// It stays. Not "a reminder after a day" — a day later the person has no idea what the reminder is
/// about, and by then they have already stopped associating it with the screen they skipped. It sits
/// there, in the way, for as long as its reason is true, and it goes the moment the reason does.
///
/// Two reasons, and they are not two shades of the same thing:
///
///   - **The history is locked.** There is a backup on the server and this device cannot open it.
///     The old messages are *there*, unreadable, and one code or one confirmation brings them back.
///   - **The code was never saved.** Everything works — and the moment this phone is lost, none of
///     it does. This one is the reason the banner exists at all: it is invisible, it is not urgent,
///     and it is catastrophic. Nobody discovers it on their own; they discover it on their next
///     phone, six months later, from a screen that cannot help them.
///
/// The second one leads to *making a new code*, and cannot lead anywhere else. A code is shown once
/// and can never be shown again — a property of how the secret is stored, not a choice made here —
/// so "show it to me again" is not a thing this app is able to offer, however much it looks like the
/// obvious button.
struct RecoveryBanner: View {
    let recovery: RecoveryStore

    /// Whether the user was shown a code and skipped saving it. Not something the SDK knows or could
    /// know — it is a fact about what happened on a screen — so it is carried in rather than asked for.
    let didSkipSavingCode: Bool

    var onTap: (Reason) -> Void

    enum Reason {
        case locked
        case unsaved
    }

    var body: some View {
        if let reason {
            Button {
                onTap(reason)
            } label: {
                HStack(spacing: Theme.Spacing.close) {
                    Image(systemName: reason == .locked ? "lock.fill" : "key.horizontal.fill")

                    Text(reason == .locked ? Strings.Recovery.bannerLocked
                                           : Strings.Recovery.bannerUnsaved)
                        .font(.callout)
                        .multilineTextAlignment(.leading)

                    Spacer(minLength: Theme.Spacing.close)

                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                }
                .foregroundStyle(.orange)
                .padding(.horizontal, Theme.Spacing.roomy)
                .padding(.vertical, Theme.Spacing.normal)
                .frame(maxWidth: .infinity)
                .background(.orange.opacity(Theme.Backdrop.wash))
            }
            .buttonStyle(.plain)
        }
    }

    /// Locked beats unsaved when both are somehow true: a person who cannot read their conversations
    /// has a problem *now*, and the one they have in six months can wait until this one is fixed.
    private var reason: Reason? {
        if recovery.protection == .keyNeeded { return .locked }
        if didSkipSavingCode { return .unsaved }
        return nil
    }
}
