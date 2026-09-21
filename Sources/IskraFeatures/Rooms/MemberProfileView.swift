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

    /// Writing to this person — see `PersonalChats`.
    @Environment(\.personalChats) private var personalChats

    /// And putting that conversation on the screen once there is one.
    @Environment(\.openRoom) private var openRoom

    /// So the screen does not offer to start a conversation with yourself.
    @Environment(\.currentUserID) private var currentUserID

    /// The conversation with this person, if there is already one, which decides both what the
    /// button says and whether pressing it needs the network.
    ///
    /// Held in state and looked up once when the screen appears rather than read in `body`: it is a
    /// question for the SDK, and `body` runs whenever anything on this screen moves.
    @State private var existingChat: String?

    /// True while a new chat is being made. Creating one is a round trip to the server and then a
    /// wait for the room to exist locally — several seconds on a slow homeserver — and a button
    /// that looks unpressed for that long gets pressed again, which makes a second room.
    @State private var isOpening = false

    /// The server would not make the room. Said out loud, because the alternative is a button that
    /// visibly does nothing.
    @State private var failure: RoomCreationFailure?

    var body: some View {
        Form {
            Section {
                ProfileHeader(name: member.name,
                              avatarURL: member.avatarURL,
                              subtitle: member.id,
                              seed: member.id,
                              // The ID is exactly the string somebody opens this screen to copy.
                              isSubtitleSelectable: true)
                    .profileHeaderRow()
            }

            writeTo

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
        .failureAlert($failure)
        // Once, on the way in. The answer cannot change while this screen is up — nothing here
        // starts a chat except the button below, which sets it itself.
        .task { existingChat = personalChats?.existing(with: member.id) }
    }

    /// The way from a name in a list to a conversation with the person behind it.
    ///
    /// One button with two labels, because it is one act with two histories: if there is already a
    /// chat this goes to it, and if there is not this starts one. Saying "write" over a chat that
    /// exists would promise a blank page and deliver three years of history; saying "go to the
    /// chat" where there is none would name a place that is not there. The word follows the fact.
    ///
    /// Not shown for yourself — you are in the member list of every room you are in, and a
    /// conversation with yourself is a thing Matrix will happily create and nobody wants. Not shown
    /// either where nothing could act on it: with no `openRoom` there is no room list behind this
    /// screen to put a conversation into.
    @ViewBuilder
    private var writeTo: some View {
        if personalChats != nil, openRoom != nil, member.id != currentUserID {
            Section {
                Button {
                    Task { await write() }
                } label: {
                    HStack {
                        Label(String(app: existingChat == nil ? Strings.Room.Manage.write
                                                              : Strings.Room.Manage.goToChat),
                              systemImage: existingChat == nil ? "square.and.pencil" : "bubble.left.and.text.bubble.right")

                        if isOpening {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                // Opening a chat that exists is a local act and works with no network at all.
                // Making one is not: it is `createRoom` on the homeserver, so offline the button
                // is withheld rather than offered and then refused.
                .disabled(isOpening || (isOffline && existingChat == nil))
            }
        }
    }

    private func write() async {
        guard let personalChats, !isOpening else { return }
        isOpening = true
        defer { isOpening = false }

        guard let roomID = await personalChats.open(with: member.id) else {
            failure = .refused
            return
        }

        existingChat = roomID
        // The room replaces what this screen is standing on, so this screen goes with it. Both,
        // rather than either: the selection changing rebuilds the conversation column, and the
        // dismiss is what takes the profile off the screen on a phone, where this screen *is* the
        // column it is being asked to leave.
        openRoom?(roomID)
        dismiss()
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
