import SwiftUI
import IskraCore
import IskraDesign

/// A notice shown in place of the message composer when the room does not allow
/// the current account to post.
struct ReadOnlyBanner: View {
    var body: some View {
        HStack(spacing: Theme.Spacing.normal) {
            Image(systemName: "lock.fill")
                .font(.body.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            Text(String(app: Strings.Room.readOnly))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Theme.Spacing.roomy)
        .padding(.vertical, Theme.Spacing.normal)
        .frame(minHeight: Theme.Size.composerControl)
        .navigationGlass(in: .rect(cornerRadius: Theme.Radius.bubble, style: .continuous))
        .padding(.horizontal, Theme.Spacing.normal)
        .padding(.vertical, Theme.Spacing.close)
    }
}
