import SwiftUI
import IskraCore
import IskraDesign

/// The strip across the top of the chat list that will not let the user forget.
///
/// It stays. Not "a reminder after a day" — a day later the person has no idea what the reminder is
/// about, and by then they have already stopped associating it with the screen they skipped. It sits
/// there, in the way, for as long as its reason is true, and it goes the moment the reason does.
///
/// **The history is locked.** There is a backup on the server and this device cannot open it. The old
/// messages are *there*, unreadable, and one code or one confirmation brings them back.
///
/// It used to have a second reason — "your recovery code was never saved" — which was lit by the
/// Skip button on the screen that shows the code. That button is gone: the code screen now has one
/// way out, and it is inert until the reader ticks a box saying they have written the code down. So
/// there is no longer any such thing as a code the app knows was skipped, and a banner about one
/// would be a banner that could never appear. What the Skip button bought — a moment where a person
/// admits to themselves that they have not saved anything — is bought by the tick instead, at the
/// moment it can still be acted on rather than six months later.
struct RecoveryBanner: View {
    let recovery: RecoveryStore

    var onTap: () -> Void

    var body: some View {
        if recovery.protection == .keyNeeded {
            Button(action: onTap) {
                HStack(spacing: Theme.Spacing.close) {
                    // The colour is spent on the symbol and nowhere else. The words used to be orange
                    // too, on an orange wash, and orange-on-pale-orange is about 2:1 — a long way
                    // under the 4.5:1 that ordinary text has to clear, and it was the *warning* that
                    // was hardest to read. Apple's own banners do it this way round: a tinted symbol
                    // carries the alarm, and the sentence stays in the colour sentences are.
                    Image(systemName: "lock.fill")
                        .foregroundStyle(.orange)

                    Text(Strings.Recovery.bannerLocked)
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)

                    Spacer(minLength: Theme.Spacing.close)

                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, Theme.Spacing.roomy)
                .padding(.vertical, Theme.Spacing.normal)
                // A row of one line of `.callout` between two `Spacing.normal` paddings comes out
                // under 44pt, and this is a button. It is the one control in the app a person is
                // meant to hit while their mind is on something else.
                .frame(maxWidth: .infinity, minHeight: Theme.Size.minimumTapTarget)
                .background(.orange.opacity(Theme.Backdrop.wash))
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            // The chevron is what tells a sighted reader this strip goes somewhere. A screen reader
            // heard the sentence, heard "button", and had no idea what pressing it would do.
            .accessibilityHint(Text(Strings.Recovery.bannerHint))
        }
    }
}
