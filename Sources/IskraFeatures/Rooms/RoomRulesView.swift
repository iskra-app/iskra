import SwiftUI
import IskraCore
import IskraDesign

/// Who runs the room, and which rung may do what — "Roles and permissions", reached from the
/// editing screen by whoever may change the room's power levels.
///
/// Two lists. The people with a role, in the same rows as the participants tab — a tap opens their
/// page, a swipe changes their role or takes it away — with "Add" under them to appoint somebody
/// from the rest of the room. And the room's rules, each one a choice of
/// the lowest rung that may: everyone, moderators, administrators. A rule this account cannot move
/// — one standing above its own rung — is shown as a fact, not as a disabled picker.
///
/// No `@Environment(\.dismiss)` here: this screen can sit in the sidebar's stack on the Mac, where
/// reading it alongside a push of its own hangs the window. See CLAUDE.md.
struct RoomRulesView: View {
    let details: RoomDetailsStore

    @Environment(\.isOffline) private var isOffline

    @State private var openedMember: String?
    @State private var isAppointing = false

    /// The people this account could make a moderator or an administrator: in the room, below it,
    /// and with no role yet.
    private var candidates: [RoomMemberSummary] {
        details.members.filter { $0.role == .member && !appointableRoles(for: $0).isEmpty }
    }

    private func appointableRoles(for member: RoomMemberSummary) -> [RoomRole] {
        details.assignableRoles(for: member).filter { $0 != .member }
    }

    var body: some View {
        Form {
            Section {
                ForEach(details.staff) { member in
                    MemberRow(member: member, details: details, demotes: true) { openedMember = member.id }
                }
                if details.permissions.canChangeRoles && !isOffline {
                    Button {
                        isAppointing = true
                    } label: {
                        Label {
                            Text(Strings.Room.Rules.addStaff)
                        } icon: {
                            Image(systemName: "plus")
                        }
                    }
                }
            } header: {
                Text(Strings.Room.Rules.staffHeader)
            } footer: {
                Text(Strings.Room.Rules.staffFooter)
            }

            if let rules = details.rules {
                Section {
                    ForEach(RoomRule.allCases) { rule in
                        row(rule, in: rules)
                    }
                } header: {
                    Text(Strings.Room.Rules.rulesHeader)
                } footer: {
                    Text(Strings.Room.Rules.rulesFooter)
                }
            }
        }
        .formStyle(.groupedRows)
        .navigationTitle(String(app: Strings.Room.Rules.title))
        #if !os(macOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .memberProfiles($openedMember, details: details)
        .pageSheet(isPresented: $isAppointing) {
            AppointSheet(candidates: candidates,
                         roles: appointableRoles(for:),
                         appoint: { member, role in Task { await details.setRole(role, for: member) } })
        }
        .failureAlert(Binding(get: { details.failure }, set: { details.failure = $0 }))
    }

    @ViewBuilder
    private func row(_ rule: RoomRule, in rules: RoomRules) -> some View {
        let current = rules.role(for: rule)
        let choices = isOffline ? [] : details.roles(for: rule)

        if choices.count > 1 {
            Picker(selection: Binding(get: { current },
                                      set: { role in Task { await details.setRule(rule, to: role) } })) {
                // Lowest rung first: "everyone" at the top, the narrowest at the bottom.
                ForEach(choices.reversed(), id: \.self) { role in
                    Text(choice(role)).tag(role)
                }
            } label: {
                Text(name(of: rule))
            }
            .accentControl()
        } else {
            LabeledContent {
                Text(choice(current))
            } label: {
                Text(name(of: rule))
            }
        }
    }

    private func name(of rule: RoomRule) -> LocalizedStringResource {
        switch rule {
        case .sendMessages: Strings.Room.Rules.sendMessages
        case .invite: Strings.Room.Rules.invite
        case .remove: Strings.Room.Rules.remove
        case .ban: Strings.Room.Rules.ban
        case .deleteOthers: Strings.Room.Rules.deleteOthers
        case .rename: Strings.Room.Rules.rename
        case .changeTopic: Strings.Room.Rules.changeTopic
        case .changePicture: Strings.Room.Rules.changePicture
        }
    }

    private func choice(_ role: RoomRole) -> LocalizedStringResource {
        switch role {
        case .member: Strings.Room.Rules.everyone
        case .moderator: Strings.Room.Rules.moderators
        case .administrator: Strings.Room.Rules.administrators
        }
    }
}

/// Picking somebody from the room to run it with you: a list of the people who have no role yet,
/// and, on a tap, the role to give them.
///
/// A sheet, so its `dismiss` is its own and the sidebar's hang does not apply.
private struct AppointSheet: View {
    let candidates: [RoomMemberSummary]
    let roles: (RoomMemberSummary) -> [RoomRole]
    let appoint: (RoomMemberSummary, RoomRole) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var chosen: RoomMemberSummary?

    var body: some View {
        NavigationStack {
            Group {
                if candidates.isEmpty {
                    ContentUnavailableView(String(app: Strings.Room.Rules.nobodyToAppoint),
                                           systemImage: "person.badge.key")
                } else {
                    List(candidates) { member in
                        Button {
                            chosen = member
                        } label: {
                            HStack(spacing: Theme.Spacing.normal) {
                                Avatar(name: member.name, url: member.avatarURL, size: Theme.Size.avatar,
                                       seed: member.id)
                                Text(member.name)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle(String(app: Strings.Room.Rules.appointTitle))
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(app: Strings.Room.Manage.cancel)) { dismiss() }
                }
            }
            .confirmationDialog(Text(Strings.Room.Manage.chooseRole),
                                isPresented: Binding(get: { chosen != nil },
                                                     set: { if !$0 { chosen = nil } }),
                                titleVisibility: .visible,
                                presenting: chosen) { member in
                ForEach(roles(member), id: \.self) { role in
                    Button(String(app: RoomRoleName.full(role))) {
                        appoint(member, role)
                        dismiss()
                    }
                }
                Button(String(app: Strings.Room.Manage.cancel), role: .cancel) {}
            } message: { member in
                Text(verbatim: member.name)
            }
        }
    }
}
