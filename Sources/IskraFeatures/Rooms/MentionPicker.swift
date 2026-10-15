import SwiftUI
import IskraCore
import IskraDesign

/// The people an "@" could mean, floating over the conversation just above the composer — Signal's
/// list, which is also Telegram's. A tap puts the name into the draft; see `ComposerMentions`.
///
/// Glass, because it is the composer's own control and floats where the attach choices float — the
/// navigation layer, not content. A face and a name per line, and the Matrix ID beside the name only
/// when the room has two people of that name, as the member list does: the ID is the part nobody
/// can copy.
struct MentionPicker: View {
    let members: [RoomMemberSummary]
    let onPick: (RoomMemberSummary) -> Void

    /// Four and a half lines, then it scrolls — the half line is what says there is more.
    private static let visibleRows: CGFloat = 4.5

    @ScaledSize(Theme.Size.avatar) private var avatar

    private var rowHeight: CGFloat { avatar + 2 * Theme.Spacing.close }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(members) { member in
                    Button { onPick(member) } label: { row(member) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.vertical, Theme.Spacing.tight)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: min(CGFloat(members.count), Self.visibleRows) * rowHeight + 2 * Theme.Spacing.tight)
        .navigationGlass(in: .rect(cornerRadius: Theme.Radius.bubble, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(Strings.Room.mentionSuggestions))
    }

    private func row(_ member: RoomMemberSummary) -> some View {
        HStack(spacing: Theme.Spacing.normal) {
            Avatar(name: member.name, url: member.avatarURL, size: avatar, seed: member.id)
            Text(verbatim: member.name)
                .lineLimit(1)
            if member.isNameAmbiguous {
                Text(verbatim: member.id)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Spacing.roomy)
        .frame(height: rowHeight)
        .contentShape(.rect)
    }
}
