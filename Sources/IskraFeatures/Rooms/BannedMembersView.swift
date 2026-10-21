import SwiftUI
import IskraCore
import IskraDesign

/// The people the room has blocked, and the way to let each of them back.
///
/// Reached from the edit screen, and only by somebody who could block them in the first place —
/// Matrix asks the same power to lift a ban as to lay one. Letting somebody back is asked about
/// first, as blocking is, and the question says the part people get wrong: the person is *allowed*
/// in again, not brought in.
struct BannedMembersView: View {
    let details: RoomDetailsStore

    @Environment(\.isOffline) private var isOffline

    @State private var unbanning: RoomMemberSummary?

    var body: some View {
        Form {
            Section {
                ForEach(details.banned) { member in
                    Button {
                        unbanning = member
                    } label: {
                        HStack(spacing: Theme.Spacing.normal) {
                            Avatar(name: member.name, url: member.avatarURL, size: Theme.Size.avatar,
                                   seed: member.id)
                            VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                                Text(member.name)
                                    .lineLimit(1)
                                if member.name != member.id {
                                    Text(member.id)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .disabled(isOffline)
                    .swipeActions {
                        Button {
                            unbanning = member
                        } label: {
                            Text(Strings.Room.Access.unban)
                        }
                        .tint(.green)
                        .disabled(isOffline)
                    }
                }
            } footer: {
                Text(Strings.Room.Access.bannedFooter)
            }
        }
        .formStyle(.groupedRows)
        .navigationTitle(String(app: Strings.Room.Access.banned))
        #if !os(macOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .confirmationDialog(Text(Strings.Room.Access.unbanQuestion(unbanning?.name ?? "")),
                            isPresented: Binding(get: { unbanning != nil }, set: { if !$0 { unbanning = nil } }),
                            titleVisibility: .visible,
                            presenting: unbanning) { member in
            Button(String(app: Strings.Room.Access.unban)) {
                Task { await details.unban(member) }
            }
        } message: { _ in
            Text(Strings.Room.Access.unbanHelp)
        }
        .failureAlert(Binding(get: { details.failure }, set: { details.failure = $0 }))
    }
}
