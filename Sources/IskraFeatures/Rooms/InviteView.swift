import SwiftUI
import IskraCore
import IskraDesign

/// "Invite", shaped like "New chat": a search field for people at the top, and under it everybody
/// this account already has a conversation with, by letter.
///
/// It searches the same two places `NewChatView` does — the conversations already here, at once,
/// and the homeserver's directory a moment later — and a Matrix ID typed in full is always somebody
/// to invite, whether or not the directory has heard of them.
///
/// Unlike "New chat", a press *chooses* rather than acts. An invitation cannot be taken back from
/// this screen, and a list of faces under a moving thumb is exactly where the wrong one gets
/// pressed; so people are ticked, and nothing leaves until "Invite" in the corner. Whoever is ticked
/// stays ticked across searches, so a room can be filled from three different queries.
struct InviteView: View {
    let details: RoomDetailsStore
    let people: PersonalChats

    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var found: [PersonProfile] = []
    @State private var isSearching = false
    @State private var searchFailed = false

    /// Who is ticked, in the order they were ticked, with what is known about them — a person found
    /// by one search is still drawn by name after the query that found them is gone.
    @State private var chosen: [PersonProfile] = []
    @State private var isInviting = false
    @State private var failure: RoomActionFailure?

    var body: some View {
        NavigationStack {
            List {
                if trimmedQuery.isEmpty {
                    chosenStrangers
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
            .disabled(isInviting)
            .failureAlert($failure)
            .navigationTitle(Text(Strings.Room.Manage.invite))
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(app: Strings.Room.Manage.cancel)) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isInviting {
                        ProgressView()
                    } else {
                        Button(String(app: chosen.isEmpty ? Strings.Room.Manage.invite
                                                          : Strings.Room.Invite.inviteCount(chosen.count))) {
                            Task { await invite() }
                        }
                        .disabled(chosen.isEmpty)
                    }
                }
            }
        }
    }

    // MARK: - The list with nothing typed

    /// The people ticked from a search who are not in the contacts below — without this they would
    /// be chosen and invisible the moment the field is cleared.
    @ViewBuilder
    private var chosenStrangers: some View {
        let contactIDs = Set(contacts.map(\.id))
        let strangers = chosen.filter { !contactIDs.contains($0.id) }
        if !strangers.isEmpty {
            Section {
                ForEach(strangers) { person in
                    row(id: person.id, name: person.name, subtitle: person.id, avatarURL: person.avatarURL)
                }
            } header: {
                Text(Strings.Room.Invite.chosen)
            }
        }
    }

    @ViewBuilder
    private var contactSections: some View {
        ForEach(NewChatView.byLetter(contacts), id: \.letter) { group in
            Section {
                ForEach(group.people) { contact in
                    row(id: contact.id, name: contact.name, subtitle: contact.id, avatarURL: contact.avatarURL)
                }
            } header: {
                Text(group.letter)
            }
        }
    }

    // MARK: - The list with something typed

    @ViewBuilder
    private var searchResults: some View {
        let term = trimmedQuery
        let known = contacts
            .filter { $0.name.localizedCaseInsensitiveContains(term) || $0.id.localizedCaseInsensitiveContains(term) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let knownIDs = Set(known.map(\.id))
        let strangers = found.filter { !knownIDs.contains($0.id) }

        if !known.isEmpty {
            Section {
                ForEach(known) { contact in
                    row(id: contact.id, name: contact.name, subtitle: contact.id, avatarURL: contact.avatarURL)
                }
            } header: {
                Text(Strings.RoomList.New.yourChats)
            }
        }

        Section {
            if let typed = typedMatrixID, !knownIDs.contains(typed), !strangers.contains(where: { $0.id == typed }) {
                row(id: typed, name: typed, subtitle: String(app: Strings.Room.Invite.byAddress), avatarURL: nil)
            }

            ForEach(strangers) { person in
                row(id: person.id, name: person.name, subtitle: person.id, avatarURL: person.avatarURL)
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

    /// A person, with a tick on the far side. Somebody already in the room is drawn but cannot be
    /// ticked, and says why — leaving them out would have the reader searching for a friend the
    /// list seems not to know.
    private func row(id: String, name: String, subtitle: String, avatarURL: String?) -> some View {
        let isMember = memberIDs.contains(id)
        let isChosen = chosen.contains { $0.id == id }

        return Button {
            if let index = chosen.firstIndex(where: { $0.id == id }) {
                chosen.remove(at: index)
            } else {
                chosen.append(PersonProfile(id: id, displayName: name == id ? nil : name, avatarURL: avatarURL))
            }
        } label: {
            HStack(spacing: Theme.Spacing.normal) {
                PersonRow(name: name,
                          subtitle: isMember ? String(app: Strings.Room.Invite.alreadyHere) : subtitle,
                          avatarURL: avatarURL,
                          seed: id)
                Image(systemName: isMember || isChosen ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isMember ? AnyShapeStyle(.tertiary)
                                     : isChosen ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isMember)
        .opacity(isMember ? 0.5 : 1)
        .accessibilityAddTraits(isChosen ? .isSelected : [])
    }

    // MARK: - Data

    private var contacts: [NewChatView.Contact] { people.contacts }

    private var memberIDs: Set<String> { Set(details.members.map(\.id)) }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespaces)
    }

    private var typedMatrixID: String? {
        let typed = trimmedQuery
        guard RoomDetailsStore.isMatrixID(typed), typed != people.ownUserID else { return nil }
        return typed
    }

    // MARK: - Acts

    /// The same debounce as "New chat" — see `NewChatView.searchDirectory`.
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
            let result = try await people.searchPeople(term)
            guard !Task.isCancelled else { return }
            found = result
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            found = []
            searchFailed = true
        }
        isSearching = false
    }

    /// Everybody ticked, and the sheet goes away only if all of them went. The refused stay ticked,
    /// so the alert's "OK" leaves "Invite" one press from trying them again.
    private func invite() async {
        guard !chosen.isEmpty, !isInviting else { return }
        isInviting = true
        let refused = Set(await details.invite(chosen.map(\.id)))
        isInviting = false

        if refused.isEmpty {
            dismiss()
        } else {
            chosen.removeAll { !refused.contains($0.id) }
            failure = .invite
        }
    }
}
