import SwiftUI
import IskraCore
import IskraDesign

/// Who runs the room, and which rung may do what — "Roles and permissions", reached from the
/// editing screen by whoever may change the room's power levels.
///
/// Two lists. The people with a role, in the same rows as the participants tab (a tap opens their
/// page, a swipe changes their role or removes them). And the room's rules, each one a choice of
/// the lowest rung that may: everyone, moderators, administrators. A rule this account cannot move
/// — one standing above its own rung — is shown as a fact, not as a disabled picker.
///
/// No `@Environment(\.dismiss)` here: this screen can sit in the sidebar's stack on the Mac, where
/// reading it alongside a push of its own hangs the window. See CLAUDE.md.
struct RoomRulesView: View {
    let details: RoomDetailsStore

    @Environment(\.isOffline) private var isOffline

    @State private var openedMember: String?

    var body: some View {
        Form {
            Section {
                ForEach(details.staff) { member in
                    MemberRow(member: member, details: details) { openedMember = member.id }
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
        .formStyle(.grouped)
        .navigationTitle(String(app: Strings.Room.Rules.title))
        #if !os(macOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .memberProfiles($openedMember, details: details)
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
