import SwiftUI
import IskraCore
import IskraDesign

/// What this chat is, and who is in it. Reached by pressing the header above the
/// conversation.
///
/// A real destination pushed onto the navigation stack, like `SettingsView` and for the
/// same reason: the push, the back button and the swipe back are then the system's, and
/// all three are noticeably wrong when you build them yourself.
///
/// This is also where the lock finally speaks. The header shows a closed padlock and says
/// nothing; anyone who wonders what it means presses the name, and the answer is here in
/// a sentence with no cryptography in it.
struct RoomInfoView: View {
    @State private var details: RoomDetailsStore

    init(details: RoomDetailsStore) {
        _details = State(initialValue: details)
    }

    var body: some View {
        Form {
            Section {
                identity
            }

            if let topic = details.topic, !topic.isEmpty {
                Section {
                    Text(topic)
                        .font(.callout)
                        // People write paragraphs in a room topic, and they are worth
                        // reading. Selectable, because a topic is where the invite link
                        // and the rules tend to live.
                        .textSelection(.enabled)
                } header: {
                    Text(Strings.Room.about)
                }
            }

            Section {
                privacy
            }

            members
        }
        .formStyle(.grouped)
        .navigationTitle(Text(Strings.Room.detailsTitle))
        .toolbarTitleDisplayMode(.inline)
        .task { await details.load() }
    }

    /// The room, at the top: its picture, its name, and the one line that says what it is.
    private var identity: some View {
        VStack(spacing: Theme.Spacing.close) {
            Avatar(name: details.name, url: details.avatarURL, size: Theme.Size.avatarLarge)

            Text(details.name)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)

            if let subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    // In a one-to-one chat this is the other person's Matrix ID, which is
                    // exactly the string someone opens this screen to copy.
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Spacing.close)
    }

    /// A Matrix ID in a one-to-one chat, a count of people in a room.
    ///
    /// It is not a "last seen" time, and it cannot be: the Rust SDK exposes no presence
    /// over FFI at all. An "online 5 minutes ago" invented from the last message in the
    /// conversation would be a confident lie about where somebody is — see
    /// `TimelineStore.directCounterpartID`.
    private var subtitle: String? {
        if details.isDirectChat {
            return details.counterpartID
        }
        guard details.memberCount > 0 else { return nil }
        return String(app: Strings.Room.participants(details.memberCount))
    }

    /// What the padlock in the header means, spelled out. The sentence comes from
    /// `IskraCore`, which is where the app's vocabulary for privacy lives.
    private var privacy: some View {
        Label {
            Text(details.privacy.explanation)
                .font(.callout)
                .foregroundStyle(.secondary)
        } icon: {
            Image(systemName: details.privacy.iconName)
                .foregroundStyle(details.privacy == .protected ? Color.secondary : Color.orange)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var members: some View {
        Section {
            if details.isLoadingMembers && details.members.isEmpty {
                // Not an empty list: a room always has at least us in it, so "no one is
                // here" is never the truth — it only ever means we have not looked yet.
                ProgressView()
                    .frame(maxWidth: .infinity)
            } else {
                ForEach(details.members) { member in
                    MemberRow(member: member)
                }
            }
        } header: {
            Text(Strings.Room.participants(details.memberCount))
        }
    }
}

/// One person in the room: their face, their name, and what they can do here.
private struct MemberRow: View {
    let member: RoomMemberSummary

    var body: some View {
        HStack(spacing: Theme.Spacing.normal) {
            Avatar(name: member.name, url: member.avatarURL, size: Theme.Size.avatar)

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
        .accessibilityElement(children: .combine)
    }

    /// Only the people who run the room are labelled. Everyone else is just here, and a
    /// badge on every single row would say nothing at all.
    private var roleName: LocalizedStringResource? {
        switch member.role {
        case .administrator: Strings.Room.administrator
        case .moderator: Strings.Room.moderator
        case .member: nil
        }
    }
}
