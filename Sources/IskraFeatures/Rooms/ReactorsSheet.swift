import SwiftUI
import IskraCore
import IskraDesign

/// Who reacted to a message, and with what — opened from the message menu in a group, the way
/// Telegram's "N reactions" row opens its list. In a personal chat the question answers itself, so
/// the row is not offered there (see `MessageHandlers.loadReactors`).
///
/// Tabs across the top: everybody, then one per emoji with its count. Each line is a face, a name
/// and the emoji they left — so "All" reads as a list of people, not of emoji.
struct ReactorsSheet: View {
    let reactions: [MessageReaction]
    let load: () async -> [Reactor]

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
            .safeAreaInset(edge: .top, spacing: 0) { tabs }
            .navigationTitle(Text(Strings.Message.Menu.reactors(total)))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Text(Strings.Devices.done) }
                }
            }
            .task { reactors = await load() }
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
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
            .padding(.vertical, Theme.Spacing.close)
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
