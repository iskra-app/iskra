import SwiftUI
import IskraCore
import IskraDesign

/// Who reacted to a message, and with what — opened from the message menu in a group, the way
/// Telegram's "N reactions" row opens its list, or by holding a reaction under the message, the way
/// Signal's does. In a personal chat the question answers itself, so neither is offered there (see
/// `MessageHandlers.loadReactors`).
///
/// Tabs across the top: everybody, then one per emoji with its count. Each line is a face, a name
/// and the emoji they left — so "All" reads as a list of people, not of emoji. Opened from a pill,
/// it starts on that pill's emoji: the one held is the one being asked about.
struct ReactorsSheet: View {
    let reactions: [MessageReaction]
    let load: () async -> [Reactor]

    init(reactions: [MessageReaction], filter: String? = nil, load: @escaping () async -> [Reactor]) {
        self.reactions = reactions
        self.load = load
        _filter = State(initialValue: filter)
    }

    @Environment(\.dismiss) private var dismiss

    @State private var reactors: [Reactor]?
    /// The emoji shown, or nil for everybody.
    @State private var filter: String?

    private var shown: [Reactor] {
        guard let reactors else { return [] }
        guard let filter else { return reactors }
        return reactors.filter { $0.key == filter }
    }

    private var total: Int { reactions.reduce(0) { $0 + $1.count } }

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
                ForEach(shown) { reactor in
                    HStack(spacing: Theme.Spacing.normal) {
                        Avatar(name: reactor.name, url: reactor.avatarURL, size: Theme.Size.avatar, seed: reactor.userID)
                        Text(verbatim: reactor.name)
                            .lineLimit(1)
                        Spacer(minLength: Theme.Spacing.close)
                        Text(verbatim: reactor.key)
                            .font(.title3)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .animation(.smooth(duration: Theme.Timing.chrome), value: filter)
            .safeAreaInset(edge: .top, spacing: 0) { tabs }
            .navigationTitle(Text(Strings.Message.Menu.reactors(total)))
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
            .task { reactors = await load() }
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
                    Text(Strings.Message.Menu.reactorsAll(total))
                })
                ForEach(reactions) { reaction in
                    chip(isSelected: filter == reaction.key, action: { filter = reaction.key }, label: {
                        Text(verbatim: "\(reaction.key) \(reaction.count)")
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
                       load: (() async -> [Reactor])?) -> some View {
        sheet(item: request) { request in
            if let load {
                ReactorsSheet(reactions: reactions, filter: request.filter, load: load)
            }
        }
    }
}
