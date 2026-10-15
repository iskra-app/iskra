import SwiftUI
import IskraCore
import IskraDesign

/// One person in the room: their face, their name, and what they can do here.
///
/// A tap opens their page (`RoomMemberProfile`). The two acts a room allows against somebody —
/// moving them to another rung, taking them out of it — are on a sideways swipe as well: fast for
/// whoever knows it is there, and a shortcut to what the profile spells out rather than the only
/// way to reach it.
///
/// A button, not a `NavigationLink`, so there is no chevron at the end of the row: the badge with
/// the person's role is what sits at the trailing edge, and a chevron after it crowded out the one
/// thing on the row worth reading. The screen that holds the list does the pushing — see
/// `memberProfiles(_:details:)`.
///
/// Nothing is ever shown disabled. What the room refuses simply is not drawn: a greyed-out
/// "Remove" is a promise the homeserver has already broken.
struct MemberRow: View {
    let member: RoomMemberSummary
    let roles: [RoomRole]
    let canRemove: Bool
    let setRole: (RoomRole) -> Void
    let remove: () -> Void
    let open: () -> Void

    @Environment(\.isOffline) private var isOffline

    /// The role picker, asked for by the swipe. A dialog rather than a submenu, because a swipe
    /// action that opened a menu would be a gesture inside a gesture.
    @State private var isChangingRole = false

    /// Every act here is a request to the server with no queue behind it, so offline the row is a
    /// row and nothing else — the swipe is withheld rather than offered and then refused.
    private var canAct: Bool {
        !isOffline && (!roles.isEmpty || canRemove)
    }

    var body: some View {
        Button(action: open) {
            HStack(spacing: Theme.Spacing.normal) {
                Avatar(name: member.name, url: member.avatarURL, size: Theme.Size.avatar,
                       seed: member.id)

                VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                    Text(member.name)
                        .font(.body)
                        .lineLimit(1)

                    // Shown only when it settles something. Matrix display names are neither
                    // unique nor verified, so two people in a room can both call themselves
                    // "Boris" — the SDK notices, and the ID underneath is the part that
                    // cannot be copied.
                    if member.isNameAmbiguous, member.name != member.id {
                        Text(member.id)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)

                if let role = roleName {
                    Text(role)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, Theme.Spacing.tight)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if canAct {
                if canRemove {
                    Button(role: .destructive, action: remove) {
                        Label(String(app: Strings.Room.Manage.remove), systemImage: "person.badge.minus")
                    }
                }

                if !roles.isEmpty {
                    Button {
                        isChangingRole = true
                    } label: {
                        Label(String(app: Strings.Room.Manage.role), systemImage: "person.badge.key")
                    }
                    .tint(.indigo)
                }
            }
        }
        .confirmationDialog(Text(Strings.Room.Manage.roleQuestion(member.name)),
                            isPresented: $isChangingRole,
                            titleVisibility: .visible) {
            ForEach(roles, id: \.self) { role in
                Button(String(localized: RoomRoleName.full(role))) { setRole(role) }
            }
            Button(String(app: Strings.Room.Manage.cancel), role: .cancel) {}
        }
    }

    /// Only the people who run the room are labelled. Everyone else is just here, and a
    /// badge on every single row would say nothing at all.
    private var roleName: LocalizedStringResource? {
        member.role == .member ? nil : RoomRoleName.full(member.role)
    }
}

extension MemberRow {
    /// A row for somebody in the room behind `details`, with the room's own rules about what this
    /// account may do to them.
    init(member: RoomMemberSummary, details: RoomDetailsStore, open: @escaping () -> Void) {
        self.init(member: member,
                  roles: details.assignableRoles(for: member),
                  canRemove: details.permissions.canRemove && details.canManage(member),
                  setRole: { role in Task { await details.setRole(role, for: member) } },
                  remove: { Task { await details.remove(member) } },
                  open: open)
    }
}

/// The words for the three rungs.
enum RoomRoleName {
    /// One person's role, named in full — including the one the list leaves blank.
    static func full(_ role: RoomRole) -> LocalizedStringResource {
        switch role {
        case .administrator: Strings.Room.administrator
        case .moderator: Strings.Room.moderator
        case .member: Strings.Room.Manage.member
        }
    }
}

extension View {
    /// Pushes a person's page when a `MemberRow` asks for one. The page reads the person out of
    /// `details` by ID, so a role changed on it shows there and back on the list alike — and it
    /// asks before blocking, since nothing under it would.
    func memberProfiles(_ opened: Binding<String?>, details: RoomDetailsStore) -> some View {
        navigationDestination(item: opened) { userID in
            RoomMemberProfile(details: details, userID: userID)
        }
    }
}
