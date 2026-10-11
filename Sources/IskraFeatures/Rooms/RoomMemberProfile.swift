import SwiftUI
import IskraCore
import IskraDesign

/// A person's page opened from inside a conversation — a name in a grey line ("Аня joined"), or a
/// face beside a message — rather than from the member list.
///
/// The page is the member list's own (`MemberProfileView`), built from the same room details with the
/// same rules about who may do what to whom. The one difference is that nothing may have loaded the
/// members yet: the reader went straight from the conversation to a name, so the list is fetched
/// here, and the page shows when the person is in it.
struct RoomMemberProfile: View {
    let details: RoomDetailsStore
    let userID: String

    var body: some View {
        Group {
            if let member = details.members.first(where: { $0.id == userID }) {
                MemberProfileView(member: member,
                                  roles: details.assignableRoles(for: member),
                                  canRemove: details.permissions.canRemove && details.canManage(member),
                                  canBlock: details.permissions.canBan && details.canManage(member),
                                  setRole: { role in Task { await details.setRole(role, for: member) } },
                                  remove: { Task { await details.remove(member) } },
                                  block: { Task { await details.ban(member) } },
                                  asksBeforeBlocking: true)
            } else if details.isLoadingMembers {
                ProgressView { Text(Strings.Profile.loading) }
            } else {
                // Somebody who has left — the grey line said so, and it is still in the history.
                ContentUnavailableView(String(app: Strings.Profile.notInRoom),
                                       systemImage: "person.crop.circle.badge.questionmark")
            }
        }
        .task {
            if details.members.isEmpty { await details.load() }
        }
    }
}
