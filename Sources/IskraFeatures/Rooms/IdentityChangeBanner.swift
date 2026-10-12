import SwiftUI
import IskraCore
import IskraDesign

/// The strip that says somebody in this room has new keys — see `IdentityChangesStore`.
///
/// One person at a time, the oldest first: answering one brings up the next. A stack of them
/// would be a wall of warnings nobody reads, and each of these is a question only the reader can
/// answer about one particular person.
///
/// No glass, like `OfflineBanner`: it is a statement about the content, not a control floating
/// over it. The serious case — keys changed after the person was verified — is tinted, so the two
/// cannot be mistaken for each other at a glance.
struct IdentityChangeBanner: View {
    let change: IdentityChange
    let onAcknowledge: () -> Void

    private var isSerious: Bool { change.kind == .changedAfterVerification }

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.close) {
            Image(systemName: isSerious ? "exclamationmark.shield.fill" : "shield.lefthalf.filled")
                .font(.title3)
                .foregroundStyle(isSerious ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                Text(isSerious ? Strings.Room.Identity.violationTitle(change.name)
                               : Strings.Room.Identity.changedTitle(change.name))
                    .font(.subheadline.weight(.semibold))
                Text(isSerious ? Strings.Room.Identity.violationBody : Strings.Room.Identity.changedBody)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button(action: onAcknowledge) {
                    Text(isSerious ? Strings.Room.Identity.withdraw : Strings.Room.Identity.understood)
                        .font(.footnote.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .tint(isSerious ? .orange : .accentColor)
                .padding(.top, Theme.Spacing.tight)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Theme.Spacing.roomy)
        .background(isSerious ? AnyShapeStyle(Color.orange.opacity(Theme.Opacity.warningWash)) : AnyShapeStyle(.bar))
        .accessibilityElement(children: .combine)
    }
}
