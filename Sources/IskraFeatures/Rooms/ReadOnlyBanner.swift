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

/// In place of the composer in a personal chat with somebody you have blocked: what is going on,
/// and the way to undo it.
///
/// Without it the chat looked like any other — a field to write in, a person who simply stopped
/// answering — when in fact their messages are not reaching you at all. Telegram says so in the
/// same place, and offers the same one button.
struct BlockedBanner: View {
    let unblock: () -> Void

    @Environment(\.accent) private var accent

    var body: some View {
        HStack(spacing: Theme.Spacing.normal) {
            Image(systemName: "hand.raised.fill")
                .font(.body.weight(.semibold))
                .foregroundStyle(.red)
                .accessibilityHidden(true)

            Text(Strings.Profile.blockedNotice)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

            Button(String(app: Strings.Settings.unblock), action: unblock)
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.plain)
                .foregroundStyle(accent.color)
        }
        .padding(.horizontal, Theme.Spacing.roomy)
        .padding(.vertical, Theme.Spacing.normal)
        .frame(minHeight: Theme.Size.composerControl)
        .navigationGlass(in: .rect(cornerRadius: Theme.Radius.bubble, style: .continuous))
        .padding(.horizontal, Theme.Spacing.normal)
        .padding(.vertical, Theme.Spacing.close)
    }
}
