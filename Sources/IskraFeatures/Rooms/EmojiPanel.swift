import SwiftUI
import IskraDesign

// The picker of every emoji, and the button one emoji is drawn as.
//
// Both were private to `MessageMenuOverlay` while the menu was the only place that offered more
// than six. The reactions screen in settings now offers the same, and it has to be the *same*
// picker rather than one that looks like it: two grids of every emoji, kept in step by hand, is
// two chances for the setting to offer a reaction the menu cannot send.

/// One emoji, pressable, and lit when it is already yours.
///
/// "Already yours" matters more here than it looks: pressing it again takes the reaction back,
/// and a bar that drew the one you left exactly like the five you did not would make removing a
/// reaction a thing you do by accident and cannot see you have done.
struct EmojiButton: View {
    let emoji: String
    let isMine: Bool

    /// How big the circle is. Handed in rather than taken from `Theme`, because the bar has to
    /// fit seven of these across a menu and the grid has all the room in the world.
    var size: CGFloat = Theme.Size.reactionCell

    let accent: AccentTheme
    let perform: () -> Void

    var body: some View {
        Button(action: perform) {
            Text(emoji)
                .font(.title2)
                .minimumScaleFactor(0.7)
                .frame(width: size, height: size)
                .background {
                    if isMine { Circle().fill(accent.color.opacity(0.22)) }
                }
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(isMine ? Strings.Message.Menu.removeReaction : Strings.Message.Menu.addReaction))
        .accessibilityValue(emoji)
    }
}

// MARK: - And all the rest

/// Every emoji, when six was not enough — see `EmojiCatalog`.
///
/// Laid out the way the system's own picker is, because that is the shape people already know
/// how to use: a grid that scrolls through named groups, with a row of category buttons along
/// the bottom that jump to them. What it does *not* have is a search field, and the note on
/// `EmojiCatalog` says why.
struct EmojiPanel: View {
    let width: CGFloat
    let mine: Set<String>
    let recent: [String]
    let onPick: (String) -> Void

    /// Whether the panel draws itself as the floating thing it is over a conversation.
    ///
    /// It is, over a lifted message: a rounded pane of glass hanging off the menu, which is the
    /// navigation layer doing what the material is for. In a sheet it is not — a sheet already
    /// *is* the floating surface, and glass on top of glass is the one thing the rules here are
    /// most insistent about. So the settings screen asks for the grid and nothing else, and the
    /// sheet's own background shows through it.
    var isFloating = true

    /// How tall the panel is. Over a message it is the panel's own fixed height; in a sheet it is
    /// the sheet's, so the catalogue fills what it was given rather than floating in the top of it.
    var height: CGFloat?

    @Environment(\.accent) private var accent

    /// Which tab is lit. Followed by the scroll rather than driving it — pressing a tab jumps
    /// the grid, and the grid is then free to be scrolled somewhere else by hand.
    @State private var selected = EmojiCatalog.categories.first?.id ?? ""

    /// Where the grid is scrolled — moved *by point* when a tab is pressed. See `offset(of:)`.
    @State private var position = ScrollPosition()

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: Theme.Size.reactionCell), spacing: 0)]
    }

    @ViewBuilder
    var body: some View {
        if isFloating {
            grid
                .clipShape(MessageMenuOverlay.panel)
                .navigationGlass(in: MessageMenuOverlay.panel)
        } else {
            grid
        }
    }

    private var grid: some View {
        VStack(spacing: 0) {
            ScrollView {
                    LazyVStack(alignment: .leading, spacing: Theme.Spacing.close) {
                        if !recent.isEmpty {
                            // As many across as the bar outside has cells — the five and its
                            // "+" — whatever the panel's width, so the twelve most recent land as
                            // two tidy rows on the same columns, which is the whole reason to keep
                            // them.
                            section(id: "recent",
                                    title: Strings.Reactions.recent,
                                    emoji: recent,
                                    across: QuickReaction.allCases.count + 1)
                        }

                        ForEach(EmojiCatalog.categories) { category in
                            section(id: category.id, title: category.title, emoji: category.emoji)
                        }
                    }
                    // The grid is held to the panel's width here rather than by the frame at
                    // the bottom of this view. A `LazyVGrid` inside a `ScrollView` takes the
                    // width it is *proposed*, and a frame applied outside the scroll view is
                    // not a proposal — it is a crop that the grid's adaptive columns had
                    // already been laid out past, in both directions.
                    .frame(width: width - Theme.Spacing.close * 2)
                    .padding(.horizontal, Theme.Spacing.close)
                    .padding(.bottom, Theme.Spacing.close)
            }
            .scrollPosition($position)

            tabs
        }
        .frame(width: width, height: height ?? Theme.Size.emojiPanel)
    }

    /// - Parameter across: how many to a row. Left off, the grid fits as many as the panel
    ///   takes — which is what every category wants, and what "recent" does not.
    private func section(id: String,
                         title: LocalizedStringResource,
                         emoji: [String],
                         across: Int? = nil) -> some View {
        let columns = across.map { Array(repeating: GridItem(.flexible(), spacing: 0), count: $0) }
            ?? self.columns

        return Section {
            LazyVGrid(columns: columns, spacing: 0) {
                ForEach(emoji, id: \.self) { character in
                    EmojiButton(emoji: character,
                                isMine: mine.contains(character),
                                accent: accent) { onPick(character) }
                }
            }
        } header: {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: Theme.Size.emojiHeader,
                       maxHeight: Theme.Size.emojiHeader, alignment: .leading)
                // Scrolling away with its group rather than pinned to the top of the panel. A
                // pinned header needs something opaque behind it or the emoji slide through the
                // words — and the only thing to put behind it here is another material, over
                // glass, which is the one thing the glass rules are most insistent about.
                .id(id)
        }
    }

    /// Where a category starts, worked out rather than asked for.
    ///
    /// `scrollTo(id)` was asked, and it lands wherever the lazy stack *estimates* a group to be —
    /// with nearly two thousand emoji, the groups below the screen have never been built and
    /// their heights are guesses, so the flags tab stopped somewhere in the symbols. But every
    /// row of this grid is one cell tall and every heading one height, so where each group begins
    /// is plain arithmetic, and the scroll goes to that point exactly.
    private func offset(of id: String) -> CGFloat {
        let gap = Theme.Spacing.close
        let cell = Theme.Size.reactionCell
        let across = max(1, Int((width - gap * 2) / cell))

        func height(rows count: Int, across: Int) -> CGFloat {
            Theme.Size.emojiHeader + gap + CGFloat((count + across - 1) / across) * cell + gap
        }

        var y: CGFloat = 0
        if !recent.isEmpty {
            if id == "recent" { return 0 }
            y += height(rows: recent.count, across: QuickReaction.allCases.count + 1)
        }
        for category in EmojiCatalog.categories {
            if category.id == id { return y }
            y += height(rows: category.emoji.count, across: across)
        }
        return y
    }

    /// The row of category buttons along the bottom. SF Symbols rather than a representative
    /// emoji from each group: a smiley standing for "smileys" is indistinguishable from a
    /// smiley you can send, and this row is not sendable.
    private var tabs: some View {
        HStack(spacing: 0) {
            ForEach(EmojiCatalog.categories) { category in
                Button {
                    selected = category.id
                    withAnimation(.smooth(duration: Theme.Timing.chrome)) {
                        position.scrollTo(y: offset(of: category.id))
                    }
                } label: {
                    Image(systemName: category.symbol)
                        .font(.footnote)
                        .foregroundStyle(selected == category.id ? AnyShapeStyle(accent.color) : AnyShapeStyle(.secondary))
                        .frame(maxWidth: .infinity)
                        .frame(height: Theme.Size.menuRow)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(category.title))
                .accessibilityAddTraits(selected == category.id ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(.horizontal, Theme.Spacing.close)
        .background(alignment: .top) {
            Rectangle()
                .fill(.primary.opacity(0.1))
                .frame(height: Theme.Border.hairline)
        }
    }
}
