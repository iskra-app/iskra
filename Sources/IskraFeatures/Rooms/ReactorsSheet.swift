import SwiftUI
import IskraCore
import IskraDesign

/// Who reacted to a message, and with what — opened from the message menu in a group, the way
/// Telegram's "N reactions" row opens its list, or by holding a reaction under the message, the way
/// Signal's does. In a personal chat the question answers itself, so neither is offered there (see
/// `MessageHandlers.loadReactors`).
///
/// Tabs across the top: everybody, then one per emoji with its count, then the people who have
/// read it. Each line is a face, a name, when — and the emoji they left, or the two ticks for
/// somebody who read it and left nothing: "All" is everybody who has done anything with the
/// message, once each, as in Telegram. Opened from a pill, it starts on that pill's emoji: the one
/// held is the one being asked about.
struct ReactorsSheet: View {
    let reactions: [MessageReaction]
    let load: () async -> [Reactor]
    /// Who has read it — see `MessageHandlers.loadReaders`. Nil where nobody can be asked.
    let loadReaders: (() async -> [Reader])?

    init(reactions: [MessageReaction], filter: String? = nil, load: @escaping () async -> [Reactor],
         loadReaders: (() async -> [Reader])? = nil) {
        self.reactions = reactions
        self.load = load
        self.loadReaders = loadReaders
        _filter = State(initialValue: filter)
    }

    @Environment(\.dismiss) private var dismiss

    @State private var reactors: [Reactor]?
    @State private var readers: [Reader] = []
    /// The emoji shown, `readFilter` for the readers alone, or nil for everybody.
    @State private var filter: String?

    /// Not an emoji anybody can leave — the tab of people who only read.
    private static let readFilter = "\u{0}read"

    /// One line of the list: a reaction, or somebody who read the message and left none.
    private struct Line: Identifiable {
        let id: String
        let userID: String
        let name: String
        let avatarURL: String?
        let key: String?
        let date: Date?
    }

    private var lines: [Line] {
        guard let reactors else { return [] }
        let reacted = reactors.map {
            Line(id: $0.id, userID: $0.userID, name: $0.name, avatarURL: $0.avatarURL, key: $0.key, date: $0.reactedAt)
        }
        let reactedIDs = Set(reactors.map(\.userID))
        let read = readers.map {
            Line(id: "read|" + $0.userID, userID: $0.userID, name: $0.name, avatarURL: $0.avatarURL, key: nil, date: $0.readAt)
        }
        switch filter {
        case nil: return reacted + read.filter { !reactedIDs.contains($0.userID) }
        case Self.readFilter: return read
        case let key?: return reacted.filter { $0.key == key }
        }
    }

    private var total: Int { reactions.reduce(0) { $0 + $1.count } }

    /// Everybody, once: who reacted, and who read it without reacting.
    private var everybody: Int {
        guard let reactors else { return total }
        return Set(reactors.map(\.userID)).union(readers.map(\.userID)).count
    }

    var body: some View {
        NavigationStack {
            List {
                if reactors == nil {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                }
                ForEach(lines) { line in
                    HStack(spacing: Theme.Spacing.normal) {
                        Avatar(name: line.name, url: line.avatarURL, size: Theme.Size.avatar, seed: line.userID)
                        VStack(alignment: .leading, spacing: Theme.Spacing.withinRun) {
                            Text(verbatim: line.name)
                                .lineLimit(1)
                            // When — only when it is known; see `Reader.readAt` for the readers
                            // who have no time.
                            if let date = line.date {
                                Text(date, format: .dateTime.day().month().hour().minute())
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: Theme.Spacing.close)
                        if let key = line.key {
                            Text(verbatim: key)
                                .font(.title3)
                        } else {
                            Image(systemName: "checkmark.message")
                                .foregroundStyle(.secondary)
                                .accessibilityLabel(Text(Strings.Message.Menu.seen(1)))
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .animation(.smooth(duration: Theme.Timing.chrome), value: filter)
            .safeAreaInset(edge: .top, spacing: 0) { tabs }
            .navigationTitle(Text(total > 0 ? Strings.Message.Menu.reactors(total)
                                             : Strings.Message.Menu.seen(readers.count)))
            #if os(iOS)
            // A sheet a thumb pulls up and flicks away, as Signal's is: the tabs are its top edge,
            // and a title bar above them would only say again what the "All" tab says.
            .toolbar(.hidden, for: .navigationBar)
            #else
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Text(Strings.Devices.done) }
                }
            }
            #endif
            .task {
                reactors = await load()
                readers = await loadReaders?() ?? []
            }
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #endif
    }

    /// "All" and a chip per emoji, scrolling sideways when a message has collected a lot of them.
    private var tabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.close) {
                chip(isSelected: filter == nil, action: { filter = nil }, label: {
                    Text(Strings.Message.Menu.reactorsAll(everybody))
                })
                ForEach(reactions) { reaction in
                    chip(isSelected: filter == reaction.key, action: { filter = reaction.key }, label: {
                        Text(verbatim: "\(reaction.key) \(reaction.count)")
                    })
                }
                if !readers.isEmpty {
                    chip(isSelected: filter == Self.readFilter, action: { filter = Self.readFilter }, label: {
                        Label {
                            Text(readers.count, format: .number)
                        } icon: {
                            Image(systemName: "checkmark.message")
                        }
                        .accessibilityLabel(Text(Strings.Message.Menu.seen(readers.count)))
                    })
                }
            }
            .padding(.horizontal, Theme.Spacing.roomy)
            .padding(.top, Theme.Spacing.generous)
            .padding(.bottom, Theme.Spacing.close)
        }
    }

    private func chip(isSelected: Bool, action: @escaping () -> Void,
                      @ViewBuilder label: () -> some View) -> some View {
        Button(action: action) {
            label()
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, Theme.Spacing.normal)
                .padding(.vertical, Theme.Spacing.tight)
                .background(isSelected ? AnyShapeStyle(.tint.opacity(Theme.Backdrop.wash)) : AnyShapeStyle(.quaternary),
                            in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Which "who reacted" list a row has asked for: everybody, or one emoji's people.
struct ReactorsRequest: Identifiable {
    let filter: String?
    var id: String { filter ?? "" }
}

extension View {
    /// The "who reacted" sheet, for a row whose reaction pills can be held. Nothing when `load` is
    /// nil — a personal chat, or a row drawn where nobody can be asked.
    func reactorsSheet(_ request: Binding<ReactorsRequest?>,
                       reactions: [MessageReaction],
                       load: (() async -> [Reactor])?,
                       loadReaders: (() async -> [Reader])? = nil) -> some View {
        sheet(item: request) { request in
            if let load {
                ReactorsSheet(reactions: reactions, filter: request.filter, load: load, loadReaders: loadReaders)
            }
        }
    }
}
