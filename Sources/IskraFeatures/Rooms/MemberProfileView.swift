import SwiftUI
import IskraCore
import IskraDesign

/// One person in a room, on a screen of their own: their face, their name, the Matrix ID
/// underneath, what they are allowed to do here — and, for whoever runs the room, what can be
/// done about them.
///
/// Reached by pressing their row in the participants tab. That press used to do nothing at all:
/// the row was a row, and every act it offered was hidden in a long press that nothing on screen
/// announced. A name is the most obviously tappable thing in a list of people, and a tap on it
/// should arrive somewhere.
///
/// The same portrait as the chat and the account above it — `ProfileHeader` — because a person is
/// introduced the same way wherever they are introduced.
struct MemberProfileView: View {
    let member: RoomMemberSummary

    /// The rungs this room will let *you* move them to: everything below your own authority, and
    /// empty when they are above you or when you are nobody in particular. The screen shows the
    /// picker only when there is a choice in it — a disabled control here would be the app
    /// advertising a power the homeserver has already refused.
    let roles: [RoomRole]
    let canRemove: Bool
    let canBlock: Bool

    let setRole: (RoomRole) -> Void
    let remove: () -> Void
    let block: () -> Void

    @Environment(\.isOffline) private var isOffline
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                ProfileHeader(name: member.name,
                              avatarURL: member.avatarURL,
                              subtitle: member.id,
                              // The ID is exactly the string somebody opens this screen to copy.
                              isSubtitleSelectable: true)
                    .profileHeaderRow()
            }

            Section {
                LabeledContent {
                    Text(name(of: member.role))
                } label: {
                    Label(String(app: Strings.Room.Manage.role), systemImage: "person.badge.key")
                }
            }

            if !roles.isEmpty {
                Section {
                    Picker(selection: Binding(get: { member.role }, set: setRole)) {
                        ForEach(roles, id: \.self) { role in
                            Text(name(of: role)).tag(role)
                        }
                    } label: {
                        Text(Strings.Room.Manage.role)
                    }
                    .pickerStyle(.inline)
                    .disabled(isOffline)
                } header: {
                    Text(Strings.Room.Manage.roleHeader)
                }
            }

            if canRemove || canBlock {
                Section {
                    if canRemove {
                        Button(role: .destructive) {
                            remove()
                            dismiss()
                        } label: {
                            Label(String(app: Strings.Room.Manage.remove), systemImage: "person.badge.minus")
                        }
                        .disabled(isOffline)
                    }

                    if canBlock {
                        Button(role: .destructive) {
                            block()
                            dismiss()
                        } label: {
                            Label(String(app: Strings.Room.Manage.block), systemImage: "hand.raised")
                        }
                        .disabled(isOffline)
                    }
                } footer: {
                    if isOffline {
                        Text(Strings.Room.Manage.offline)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .profileScreen()
    }

    /// All three rungs named, including the one the list leaves blank: on a screen about one
    /// person, "member" is an answer rather than an absence.
    private func name(of role: RoomRole) -> LocalizedStringResource {
        switch role {
        case .administrator: Strings.Room.administrator
        case .moderator: Strings.Room.moderator
        case .member: Strings.Room.Manage.member
        }
    }
}
