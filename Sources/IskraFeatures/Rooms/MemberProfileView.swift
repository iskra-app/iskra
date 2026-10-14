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

    /// Whether this page asks "Block?" itself before `block`. From the member list the list asks —
    /// it is still there under this page when it closes. From a name in the conversation there is
    /// nothing under this page that would, so it asks here. See `RoomMemberProfile`.
    var asksBeforeBlocking = false

    /// Whether the room's rungs mean anything here. Not in a personal chat: both people in one are
    /// made its administrators the moment it is created, and "Administrator" under somebody you
    /// are simply talking to is a word about the protocol, not about them.
    var showsRole = true
    @State private var isConfirmingBlock = false

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

    /// The QR code with this person's link in it — see `QRCodeSheet`.
    @State private var isShowingCode = false

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

                // Telegram's row of buttons under the portrait: the things one does *with* a person,
                // as tiles, before anything that is said *about* them. In the portrait's section, so
                // the form's gap between sections does not open up under the name.
                actionTiles
                    .profileHeaderRow()
            }

            // And then what is known about them, as one card — Telegram's "username", "bio" block.
            // The Matrix ID is the one thing here people come to copy, so it is selectable and has a
            // copy of its own in the menu.
            Section {
                MatrixIDField(userID: member.id)

                if showsRole {
                    LabeledContent {
                        Text(name(of: member.role))
                    } label: {
                        Text(Strings.Room.Manage.role)
                    }
                }
            }

            if showsRole, !roles.isEmpty {
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
                            if asksBeforeBlocking {
                                isConfirmingBlock = true
                            } else {
                                block()
                                dismiss()
                            }
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

            // The account's own block, last — the same button, in the same place, as on a
            // personal chat's page. See `PersonBlockButton`.
            if member.id != currentUserID {
                Section {
                    PersonBlockButton(userID: member.id, name: member.name)
                }
            }
        }
        .formStyle(.grouped)
        .profileScreen()
        .failureAlert($failure)
        .sheet(isPresented: $isShowingCode) {
            QRCodeSheet(name: member.name, subtitle: member.id, avatarURL: member.avatarURL,
                        seed: member.id, link: .user(member.id))
        }
        .confirmationDialog(Text(Strings.Room.Manage.blockQuestion(member.name)),
                            isPresented: $isConfirmingBlock,
                            titleVisibility: .visible) {
            Button(String(app: Strings.Room.Manage.block), role: .destructive) {
                block()
                dismiss()
            }
            Button(String(app: Strings.Room.Manage.cancel), role: .cancel) {}
        } message: {
            Text(Strings.Room.Manage.blockHelp)
        }
        // Once, on the way in. The answer cannot change while this screen is up — nothing here
        // starts a chat except the button below, which sets it itself.
        .task { existingChat = personalChats?.existing(with: member.id) }
    }

    /// Telegram's tiles: write to them, share them, and the rest behind "More".
    ///
    /// Each one a rounded card with an icon over a word, in the accent — buttons, not rows, because
    /// on a person's page these are the reasons to be there.
    private var actionTiles: some View {
        // One container for the circles, so neighbouring glass is drawn as glass beside glass and
        // not as three panes muddling where they nearly touch — see `Glass.swift`.
        NavigationGlassGroup(spacing: Theme.Spacing.close) {
            tileRow
        }
        .padding(.bottom, Theme.Spacing.close)
    }

    private var tileRow: some View {
        HStack(spacing: Theme.Spacing.close) {
            if canWrite {
                ProfileActionTile(title: Strings.Profile.message,
                                  systemImage: existingChat == nil ? "bubble.left.fill" : "bubble.left.and.text.bubble.right.fill",
                                  isBusy: isOpening) {
                    Task { await write() }
                }
                // Opening a chat that exists is a local act and works with no network at all.
                // Making one is `createRoom` on the homeserver, so offline it is withheld.
                .disabled(isOpening || (isOffline && existingChat == nil))
            }

            if let link = Self.link(to: member.id) {
                ShareLink(item: link) {
                    ProfileActionTileLabel(title: Strings.Profile.share, systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.plain)
            }

            // The ID is what people open a profile to take away with them — and across a table it is
            // taken away by a camera, not by a clipboard. It can still be copied: the ID on the card
            // below is selectable. The destructive acts stay where Telegram keeps them, in red at the
            // foot of the page, rather than behind a tile.
            ProfileActionTile(title: Strings.QR.title, systemImage: "qrcode", isBusy: false) {
                isShowingCode = true
            }
        }
    }

    /// Whether "Write" is on offer at all.
    ///
    /// One act with two histories: if there is already a chat this goes to it, and if there is not
    /// this starts one. Not for yourself — you are in the member list of every room you are in, and a
    /// conversation with yourself is a thing Matrix will happily create and nobody wants. Not either
    /// where nothing could act on it: with no `openRoom` there is no room list behind this screen to
    /// put a conversation into.
    private var canWrite: Bool {
        personalChats != nil && openRoom != nil && member.id != currentUserID
    }

    /// The person's address as a link anybody can open in any Matrix client — `matrix.to`, the
    /// protocol's own way of pointing at a person, and what Telegram's "share contact" is here.
    static func link(to userID: String) -> URL? {
        MatrixLink.user(userID).url
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
