import SwiftUI
import IskraCore
import IskraDesign

/// "New chat", the way Telegram has it: a search field for people at the top, three ways into a
/// room under it, and then everybody this account already has a conversation with, by letter.
///
/// The field is the way to a person who is not in the list yet. It searches two places at once —
/// the conversations already here, which answer instantly, and the homeserver's user directory,
/// which answers a moment later — and a Matrix ID typed in full is always somebody to write to,
/// whether or not the directory has heard of them: a server lists only the people it chooses to.
///
/// Every way out of this sheet is a room to put on screen, and all of them leave through `onOpen`.
struct NewChatView: View {
    let session: UserSession
    var onOpen: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var path: [Destination] = []
    @State private var query = ""
    @State private var found: [PersonProfile] = []
    @State private var isSearching = false
    @State private var searchFailed = false

    /// The person whose conversation is being opened or made, so their row can say so and no
    /// other row can start a second one meanwhile.
    @State private var opening: String?
    @State private var failure: RoomCreationFailure?

    enum Destination: Hashable {
        case scan
        /// Where a scanned code leads — a person's page, or a room to step into.
        case link(MatrixLink)
        case newRoom
        case publicRooms
        case joinByAddress
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if trimmedQuery.isEmpty {
                    actions
                    contactSections
                } else {
                    searchResults
                }
            }
            #if os(iOS)
            .listStyle(.plain)
            .searchable(text: $query,
                        placement: .navigationBarDrawer(displayMode: .always),
                        prompt: Text(Strings.RoomList.New.searchPrompt))
            .textInputAutocapitalization(.never)
            #else
            .searchable(text: $query, prompt: Text(Strings.RoomList.New.searchPrompt))
            #endif
            .autocorrectionDisabled()
            .scrollDismissesKeyboard(.immediately)
            .task(id: trimmedQuery) { await searchDirectory() }
            .disabled(opening != nil)
            .failureAlert($failure)
            .navigationTitle(Text(Strings.RoomList.newChat))
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(app: Strings.Room.Manage.cancel)) { dismiss() }
                }
            }
            .navigationDestination(for: Destination.self) { destination in
                switch destination {
                case .scan:
                    #if os(iOS)
                    QRScannerView { link in
                        // In place of the scanner rather than on top of it: Back from a person's
                        // page goes to "New chat", not to a camera that would read them again.
                        path = [.link(link)]
                    }
                    #else
                    EmptyView()
                    #endif
                case .link(let link):
                    MatrixLinkView(session: session, link: link, onOpen: onOpen)
                case .newRoom:
                    NewRoomView(session: session, onCreated: onOpen)
                case .publicRooms:
                    PublicRoomsView(session: session, onOpen: onOpen)
                case .joinByAddress:
                    JoinByAddressView(session: session, onJoined: onOpen)
                }
            }
        }
        #if os(macOS)
        // A Mac sheet is as small as its content lets it be, and a `List` asks for nothing: the
        // sheet came up as a title, a search field and Cancel, with the list squeezed to nothing.
        .frame(minWidth: Theme.Size.listSheetWidth, minHeight: Theme.Size.listSheetHeight)
        #endif
    }

    // MARK: - The list with nothing typed

    private var actions: some View {
        Section {
            // Not on the Mac: nobody holds a laptop up to somebody's phone.
            #if os(iOS)
            NavigationLink(value: Destination.scan) {
                ActionRow(title: Strings.QR.scan, systemImage: "qrcode.viewfinder")
            }
            #endif
            NavigationLink(value: Destination.newRoom) {
                ActionRow(title: Strings.RoomList.New.createRoom, systemImage: "person.3")
            }
            NavigationLink(value: Destination.publicRooms) {
                ActionRow(title: Strings.RoomList.New.publicRooms, systemImage: "globe")
            }
            NavigationLink(value: Destination.joinByAddress) {
                ActionRow(title: Strings.RoomList.New.joinByAddress, systemImage: "link")
            }
        }
    }

    @ViewBuilder
    private var contactSections: some View {
        ForEach(Self.byLetter(contacts), id: \.letter) { group in
            Section {
                ForEach(group.people) { contact in
                    Button { onOpen(contact.roomID) } label: {
                        PersonRow(name: contact.name, subtitle: contact.id, avatarURL: contact.avatarURL, seed: contact.id)
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text(group.letter)
            }
        }
    }

    // MARK: - The list with something typed

    @ViewBuilder
    private var searchResults: some View {
        let known = matchingContacts
        let knownIDs = Set(known.map(\.id))
        let strangers = found.filter { !knownIDs.contains($0.id) }

        if !known.isEmpty {
            Section {
                ForEach(known) { contact in
                    Button { onOpen(contact.roomID) } label: {
                        PersonRow(name: contact.name, subtitle: contact.id, avatarURL: contact.avatarURL, seed: contact.id)
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text(Strings.RoomList.New.yourChats)
            }
        }

        Section {
            if let typed = typedMatrixID, !knownIDs.contains(typed), !strangers.contains(where: { $0.id == typed }) {
                personButton(PersonProfile(id: typed, displayName: nil, avatarURL: nil),
                             subtitle: String(app: Strings.RoomList.New.writeTo))
            }

            ForEach(strangers) { person in
                personButton(person, subtitle: person.id)
            }

            if isSearching {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            } else if searchFailed {
                Text(Strings.RoomList.New.searchFailed)
                    .foregroundStyle(.secondary)
            } else if strangers.isEmpty, known.isEmpty, typedMatrixID == nil {
                Text(Strings.RoomList.New.nobodyFound)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text(Strings.RoomList.New.onServer)
        }
    }

    private func personButton(_ person: PersonProfile, subtitle: String) -> some View {
        Button {
            Task { await write(to: person.id) }
        } label: {
            PersonRow(name: person.name, subtitle: subtitle, avatarURL: person.avatarURL, seed: person.id,
                      isBusy: opening == person.id)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Data

    /// Somebody this account already has a personal chat with.
    struct Contact: Identifiable, Hashable {
        /// Their Matrix ID.
        let id: String
        let name: String
        let avatarURL: String?
        /// The conversation with them.
        let roomID: String
    }

    /// Everybody with a personal chat on this account, once each.
    ///
    /// A personal chat's `avatarSeed` is the other person's Matrix ID — `RoomInfo.avatarSeed` — and
    /// falls back to the room's own ID when the SDK cannot say who the other person is; those rooms
    /// have nobody to list. Two chats with one person (it happens: a client that did not find the
    /// first) are listed once, as the more recent, because the list is in order of recency.
    private var contacts: [Contact] { Self.contacts(in: session) }

    /// The same list for anybody else who needs it — "Invite", through `PersonalChats`.
    static func contacts(in session: UserSession) -> [Contact] {
        var seen = Set<String>()
        return session.roomList.rooms.compactMap { room in
            guard room.isDirectMessage, !room.isInvitation, room.avatarSeed.hasPrefix("@"),
                  seen.insert(room.avatarSeed).inserted else { return nil }
            return Contact(id: room.avatarSeed, name: room.name, avatarURL: room.avatarURL, roomID: room.id)
        }
    }

    private var matchingContacts: [Contact] {
        let term = trimmedQuery
        return contacts
            .filter { $0.name.localizedCaseInsensitiveContains(term) || $0.id.localizedCaseInsensitiveContains(term) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The contacts under their first letters, the way a phone's address book is read. Whatever
    /// does not start with a letter — an emoji, a digit — goes under "#", last.
    nonisolated static func byLetter(_ contacts: [Contact]) -> [(letter: String, people: [Contact])] {
        let groups = Dictionary(grouping: contacts) { contact -> String in
            guard let first = contact.name.first, first.isLetter else { return "#" }
            return String(first).uppercased()
        }
        return groups
            .map { (letter: $0.key, people: $0.value.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) }
            .sorted { lhs, rhs in
                if lhs.letter == "#" { return false }
                if rhs.letter == "#" { return true }
                return lhs.letter.localizedStandardCompare(rhs.letter) == .orderedAscending
            }
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespaces)
    }

    private var typedMatrixID: String? {
        let typed = trimmedQuery
        guard RoomDetailsStore.isMatrixID(typed), typed != session.userID else { return nil }
        return typed
    }

    // MARK: - Acts

    /// Asks the directory, a moment after the typing stops. `task(id:)` cancels the previous
    /// question when the query changes, so only the last one is ever answered on screen.
    private func searchDirectory() async {
        let term = trimmedQuery
        searchFailed = false
        guard !term.isEmpty else {
            found = []
            isSearching = false
            return
        }

        isSearching = true
        do {
            try await Task.sleep(for: .milliseconds(300))
            let people = try await session.searchPeople(term)
            guard !Task.isCancelled else { return }
            found = people
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            found = []
            searchFailed = true
        }
        isSearching = false
    }

    private func write(to userID: String) async {
        guard opening == nil else { return }
        opening = userID
        do {
            onOpen(try await session.openDirectChat(with: userID))
        } catch {
            failure = error
        }
        opening = nil
    }
}

/// One of the three ways into a room at the top of "New chat": an icon in the accent, and words.
private struct ActionRow: View {
    let title: LocalizedStringResource
    let systemImage: String

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(.tint)
        }
    }
}

/// A person: their face, their name, and a grey line under it.
struct PersonRow: View {
    let name: String
    let subtitle: String
    let avatarURL: String?
    let seed: String
    var isBusy = false

    var body: some View {
        HStack(spacing: Theme.Spacing.normal) {
            Avatar(name: name, url: avatarURL, size: Theme.Size.avatar, seed: seed)

            VStack(alignment: .leading, spacing: 0) {
                Text(name)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if isBusy { ProgressView() }
        }
        .contentShape(Rectangle())
    }
}
