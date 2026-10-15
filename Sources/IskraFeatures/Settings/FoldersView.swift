import SwiftUI
import IskraCore
import IskraDesign

/// The account's folders: the list, in the order of the tabs, with a way to make one, reorder
/// them and change any of them — and, while there are few, the three Telegram suggests.
///
/// Pushed from settings and shown in a sheet from the tabs' own menu. No `dismiss` here — it is
/// pushed onto the sidebar column on a Mac, and the reason that is not allowed is in `CLAUDE.md`.
struct FoldersView: View {
    let folders: ChatFolders
    let roomList: RoomListStore

    @Environment(\.isOffline) private var isOffline

    /// The folder open in the editor — a new one, or a copy of an existing one.
    @State private var editing: ChatFolder?

    private var suggestions: [ChatFolder] {
        let names = Set(folders.folders.map { $0.name.lowercased() })
        return ChatFolder.suggestions { String(app: Strings.Folders.suggestion($0)) }
            .filter { !names.contains($0.name.lowercased()) }
    }

    private var isFull: Bool { folders.folders.count >= ChatFolders.limit }

    var body: some View {
        Form {
            Section {
                ForEach(folders.folders) { folder in
                    Button {
                        editing = folder
                    } label: {
                        LabeledContent {
                            Text(folder.rooms(from: roomList.rooms, archived: roomList.archivedRooms).count,
                                 format: .number)
                        } label: {
                            Label(folder.name, systemImage: "folder")
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
                .onMove { source, destination in
                    Task { await folders.move(fromOffsets: source, toOffset: destination) }
                }
                .onDelete { offsets in
                    let ids = offsets.map { folders.folders[$0].id }
                    Task { for id in ids { await folders.delete(id) } }
                }

                if !isFull {
                    Button {
                        editing = ChatFolder(name: "")
                    } label: {
                        Label(String(app: Strings.Folders.new), systemImage: "plus")
                    }
                    .disabled(isOffline)
                }
            } footer: {
                Text(Strings.Folders.explanation)
            }

            if !suggestions.isEmpty, !isFull {
                Section {
                    ForEach(suggestions) { suggestion in
                        HStack {
                            Label(suggestion.name, systemImage: "folder.badge.plus")
                            Spacer()
                            Button(String(app: Strings.Folders.add)) {
                                Task { await folders.save(suggestion) }
                            }
                            .buttonStyle(.borderless)
                            .disabled(isOffline)
                        }
                    }
                } header: {
                    Text(Strings.Folders.suggested)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(String(app: Strings.Folders.title))
        #if !os(macOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !folders.folders.isEmpty {
                ToolbarItem(placement: .primaryAction) { EditButton() }
            }
        }
        #endif
        .sheet(item: $editing) { folder in
            FolderEditor(folder: folder,
                         isNew: !folders.folders.contains { $0.id == folder.id },
                         rooms: roomList.rooms + roomList.archivedRooms,
                         onSave: { saved in Task { await folders.save(saved) } },
                         onDelete: { id in Task { await folders.delete(id) } })
        }
        .failureAlert(Binding(get: { folders.failure }, set: { folders.failure = $0 }))
    }
}

/// One folder, being made or changed: its name, the kinds of chat it takes, the conditions on
/// them, and the chats named by hand on either side of the rule. Nothing is saved until "Done" —
/// unlike the rest of the app's settings, because a folder half-made is a tab over the list that
/// shows the wrong chats until the rest of it is filled in.
struct FolderEditor: View {
    @State var folder: ChatFolder
    let isNew: Bool
    let rooms: [RoomSummary]
    let onSave: (ChatFolder) -> Void
    let onDelete: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var choosing: Side?
    @State private var isConfirmingDelete = false

    enum Side: Identifiable {
        case included
        case excluded
        var id: Self { self }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(String(app: Strings.Folders.namePlaceholder), text: $folder.name)
                }

                Section {
                    ForEach(ChatFolder.Kind.allCases) { kind in
                        Toggle(isOn: Binding(get: { folder.kinds.contains(kind) },
                                             set: { on in
                                                 if on { folder.kinds.insert(kind) } else { folder.kinds.remove(kind) }
                                             })) {
                            Text(Strings.Folders.kind(kind))
                        }
                        .accentControl()
                    }
                } header: {
                    Text(Strings.Folders.kindsHeader)
                }

                Section {
                    Toggle(String(app: Strings.Folders.onlyUnread), isOn: $folder.onlyUnread).accentControl()
                    Toggle(String(app: Strings.Folders.excludesMuted), isOn: $folder.excludesMuted).accentControl()
                    Toggle(String(app: Strings.Folders.includesArchived), isOn: $folder.includesArchived).accentControl()
                } header: {
                    Text(Strings.Folders.conditionsHeader)
                }

                chats(.included)
                chats(.excluded)

                if !isNew {
                    Section {
                        Button(String(app: Strings.Folders.delete), role: .destructive) {
                            isConfirmingDelete = true
                        }
                        .tint(.red)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(String(app: isNew ? Strings.Folders.new : Strings.Folders.edit))
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(app: Strings.Folders.cancel)) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(app: Strings.Folders.done)) {
                        folder.name = folder.name.trimmingCharacters(in: .whitespacesAndNewlines)
                        onSave(folder)
                        dismiss()
                    }
                    .disabled(!folder.isMeaningful)
                }
            }
            .sheet(item: $choosing) { side in
                ChatChooser(rooms: rooms.filter { !$0.isInvitation },
                            chosen: Set(side == .included ? folder.included : folder.excluded)) { chosen in
                    let ordered = rooms.map(\.id).filter(chosen.contains)
                    if side == .included {
                        folder.included = ordered
                        folder.excluded.removeAll(where: chosen.contains)
                    } else {
                        folder.excluded = ordered
                        folder.included.removeAll(where: chosen.contains)
                    }
                }
            }
            .confirmationDialog(Text(Strings.Folders.deleteQuestion(folder.name)),
                                isPresented: $isConfirmingDelete,
                                titleVisibility: .visible) {
                Button(String(app: Strings.Folders.delete), role: .destructive) {
                    onDelete(folder.id)
                    dismiss()
                }
            } message: {
                Text(Strings.Folders.deleteHelp)
            }
        }
    }

    private func chats(_ side: Side) -> some View {
        let ids = side == .included ? folder.included : folder.excluded
        let named = ids.compactMap { id in rooms.first { $0.id == id } }
        return Section {
            ForEach(named) { room in
                HStack(spacing: Theme.Spacing.normal) {
                    RoomAvatar(name: room.name, url: room.avatarURL, size: Theme.Size.avatarSmall,
                               shape: room.isSpace ? .roundedSquare : .circle,
                               seed: room.isSpace ? nil : room.avatarSeed, faces: room.faces)
                    Text(room.name).lineLimit(1)
                }
            }
            .onDelete { offsets in
                let gone = Set(offsets.map { named[$0].id })
                if side == .included { folder.included.removeAll(where: gone.contains) }
                else { folder.excluded.removeAll(where: gone.contains) }
            }
            Button {
                choosing = side
            } label: {
                Label(String(app: Strings.Folders.addChats), systemImage: "plus")
            }
        } header: {
            Text(side == .included ? Strings.Folders.includedHeader : Strings.Folders.excludedHeader)
        }
    }
}

/// A list of chats to tick — the "add chats" of the folder editor.
struct ChatChooser: View {
    let rooms: [RoomSummary]
    @State var chosen: Set<String>
    let onDone: (Set<String>) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accent) private var accent
    @State private var query = ""

    private var shown: [RoomSummary] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return rooms }
        return rooms.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
    }

    var body: some View {
        NavigationStack {
            List(shown) { room in
                Button {
                    if chosen.contains(room.id) { chosen.remove(room.id) } else { chosen.insert(room.id) }
                } label: {
                    HStack(spacing: Theme.Spacing.normal) {
                        RoomAvatar(name: room.name, url: room.avatarURL, size: Theme.Size.avatar,
                                   shape: room.isSpace ? .roundedSquare : .circle,
                                   seed: room.isSpace ? nil : room.avatarSeed, faces: room.faces)
                        Text(room.name).lineLimit(1)
                        Spacer()
                        SelectionMark(isOn: chosen.contains(room.id))
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
            .searchable(text: $query)
            .navigationTitle(String(app: Strings.Folders.chooseChats))
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(app: Strings.Folders.cancel)) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(app: Strings.Folders.done)) {
                        onDone(chosen)
                        dismiss()
                    }
                }
            }
        }
    }
}

/// Which folders this one chat is in — the chat's own menu, from the list. A tick puts it in by
/// hand; taking one off keeps it out by hand. See `ChatFolders.set`.
struct FolderMembershipSheet: View {
    let room: RoomSummary
    let folders: ChatFolders

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(folders.folders) { folder in
                        let isIn = folder.contains(room)
                        Button {
                            Task { await folders.set(room.id, in: folder.id, !isIn) }
                        } label: {
                            HStack {
                                Label(folder.name, systemImage: "folder")
                                Spacer()
                                SelectionMark(isOn: isIn)
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                } footer: {
                    Text(Strings.Folders.membershipFooter)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(room.name)
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(app: Strings.Folders.done)) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
