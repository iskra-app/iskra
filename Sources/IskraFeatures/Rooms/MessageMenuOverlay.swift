import SwiftUI
import IskraCore
import IskraDesign

/// The drawing of the message menu — see `MessageMenu` for what it is and why it is ours.
///
/// Three things, stacked over a darkened conversation: a bar of emoji, the message itself
/// lifted off the page, and the column of verbs. The middle one is the point. A menu that
/// covers the message it is about makes the reader answer "which message was this?" from
/// memory, and the system's own menu has never made anybody do that.
struct MessageMenuOverlay: View {
    let presenter: MessageMenuPresenter

    /// Whether the "+" has been pressed and the six have become all of them.
    ///
    /// Kept here rather than in the presentation, because it is a fact about this *opening* of
    /// the menu and not about the message — closing and reopening on the same bubble starts
    /// again with the six, which is what anybody would expect.
    @State private var isPickingEmoji = false

    /// The emoji this person has reached for lately, at the top of the panel — see `RecentEmoji`.
    @AppStorage(RecentEmoji.storageKey) private var recent = ""

    /// The part of the window the menu is allowed to use, measured in `MessageMenu.space` — the
    /// same space the messages report themselves in.
    ///
    /// This is the answer to a bug worth writing down, because the API reads as though it could
    /// not happen. The layout was asking a `GeometryReader` for `safeAreaInsets`, and the reader
    /// had `.ignoresSafeArea()` on it — which is exactly what makes those insets *zero*. Having
    /// been given the whole window, the reader truthfully reports that nothing is being kept
    /// back from it. So every calculation believed the screen began at the top of the glass, and
    /// the bar of emoji over a message near the top of a conversation opened underneath the
    /// clock and the Dynamic Island, where it could be seen and not pressed.
    ///
    /// So the region is *measured* rather than asked for: a reader that does not ignore the safe
    /// area is laid out inside it, and where it lands is the answer. It costs nothing and it
    /// cannot drift, because the same geometry that moves the messages moves this.
    @State private var region: CGRect = .zero

    var body: some View {
        ZStack {
            // The dimming is the one part that *should* cover everything — status bar, island,
            // home indicator and all. It is here, outside the reader below, because a view can
            // only ignore a safe area its container has not already been inset by.
            if presenter.presentation != nil { scrim }

            GeometryReader { proxy in
                Color.clear
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(MessageMenu.space)) }
                        action: { region = $0 }

                if let presentation = presenter.presentation, region != .zero {
                    // The anchor arrives in the app-wide space, which starts at the top of the
                    // window; the region starts below the island. `resolve` does the conversion,
                    // and hands back an origin in the region's own coordinates — which is where
                    // the reader's contents are drawn from.
                    let layout = MessageMenuLayout.resolve(
                        anchor: presentation.anchor,
                        region: region,
                        isOwn: presentation.isOwn,
                        aboveHeight: aboveHeight(for: presentation),
                        listHeight: listHeight(for: presentation))

                    ZStack(alignment: .topLeading) {
                        column(presentation, layout: layout)
                            .offset(x: layout.origin.x, y: layout.origin.y)
                            .transition(.scale(scale: 0.92, anchor: presentation.isOwn ? .topTrailing : .topLeading)
                                .combined(with: .opacity))
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                    #if os(macOS)
                    .onExitCommand { close() }
                    #endif
                }
            }
        }
        // With nothing open this is an empty layer over the whole app, and an empty layer over
        // the whole app is exactly the sort of thing that eats a tap on a composer six months
        // from now. It is deaf until there is a menu in it.
        .allowsHitTesting(presenter.presentation != nil)
        // The knock that says the message is in your hand. It lands on the lift and not on the
        // action, because by the time an action is chosen the app has something else to say.
        .sensoryFeedback(.impact(weight: .medium), trigger: presenter.lifts)
        .onChange(of: presenter.presentation?.id) { _, id in
            if id == nil { isPickingEmoji = false }
        }
    }

    // MARK: - The conversation, behind

    /// The room does not go away while the menu is open; it goes *quiet*. Soft and a good deal
    /// darker, so the one bubble that is still sharp is obviously the one being talked about.
    ///
    /// On iPhone and iPad a material under the wash, because a wash dims a conversation and a
    /// material takes the *words* out of it. On a Mac only the wash: a blurred window is not
    /// how a Mac says "a menu is open" — its menus sit over a sharp window — and a whole window
    /// going soft under a right-click reads as the app having frozen. The whole screen is
    /// covered either way, toolbar and composer included: this is a modal moment, and a
    /// composer still crisp at the bottom of a dimmed room is an invitation to type into a menu.
    private var scrim: some View {
        MenuCurtain()
            .ignoresSafeArea()
            .contentShape(.rect)
            .onTapGesture { close() }
            .accessibilityLabel(Text(Strings.Message.Menu.close))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { close() }
            .transition(.opacity)
    }

    // MARK: - The arrangement

    @ViewBuilder
    private func column(_ presentation: MessageMenuPresentation,
                        layout: MessageMenuLayout) -> some View {
        let alignment: HorizontalAlignment = presentation.isOwn ? .trailing : .leading

        // One container for both sheets of glass, which is what keeps them from stacking into
        // soup where they nearly touch — see `IskraDesign/Glass.swift`.
        NavigationGlassGroup(spacing: MessageMenu.gap) {
            VStack(alignment: alignment, spacing: MessageMenu.gap) {
                if presentation.canReact {
                    if isPickingEmoji {
                        // Wider than the column it hangs off, and slid back onto the screen when
                        // the message it belongs to is near an edge — see
                        // `MessageMenuLayout.emojiWidth`. The `VStack`'s alignment puts the
                        // panel's anchored edge where the menu's is, whatever its width, so the
                        // offset is only ever the correction.
                        EmojiPanel(width: layout.emojiWidth,
                                   mine: presentation.mine,
                                   recent: RecentEmoji.list(from: recent),
                                   onPick: { react($0, in: presentation) })
                            .offset(x: layout.emojiOffset)
                            .transition(.scale(scale: 0.9, anchor: .bottom).combined(with: .opacity))
                    } else {
                        // As wide as the panel the "+" opens, not as narrow as the verbs:
                        // seven round targets in the width of a column of words came out at
                        // thumb-and-a-half apart, and a reaction is the thing people reach for
                        // most. Slid onto the screen by the same correction as the panel.
                        ReactionBar(width: layout.emojiWidth,
                                    mine: presentation.mine,
                                    onPick: { react($0, in: presentation) },
                                    onMore: {
                                        withAnimation(Theme.Timing.menuOpens) { isPickingEmoji = true }
                                    })
                            .offset(x: layout.emojiOffset)
                            .transition(.scale(scale: 0.9, anchor: .bottom).combined(with: .opacity))
                    }
                }

                lifted(presentation, layout: layout)

                // While the emoji panel is open the verbs stand aside. Both at once is a screen
                // with no conversation left on it, and the panel is a detour that ends in a
                // reaction rather than in a menu item.
                if !isPickingEmoji {
                    actions(presentation, layout: layout)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .frame(width: layout.width,
                   alignment: presentation.isOwn ? .trailing : .leading)
            // VoiceOver stays inside the menu while it is open, the way it does inside the
            // system's. Without this the swipe after "Reply" is the conversation behind the
            // dimming — a list of messages the user cannot see and cannot get out of.
            .accessibilityAddTraits(.isModal)
        }
    }

    /// The message, exactly where it was, and now the only sharp thing on screen.
    ///
    /// Given *at least* the room it had in the conversation and never less, which is a
    /// correction to how this was first written. It used to be pinned to the exact width it had
    /// been measured at, on the reasoning that an identical width means identical line breaks;
    /// what it actually meant was a bubble handed the tightest proposal it could still satisfy,
    /// which is the one proposal where a rounded point either way costs a line — and the lifted
    /// message came out narrower than the one underneath it, with its last line cut off. A
    /// maximum can only ever be looser than what the row proposed, so nothing wraps that did not
    /// wrap before, and a short message still sizes to its own words.
    ///
    /// Its height is left alone for the same reason — unless it is taller than the screen has
    /// room for. Then it is given the height `MessageMenuLayout` allows and *scrolls* in it, at
    /// full size. It used to be scaled down to fit instead, and a scaled page of text is a page
    /// of text too small to read; the long message is often the very one somebody opened the
    /// menu to copy a piece of, or to read again before answering.
    @ViewBuilder
    private func lifted(_ presentation: MessageMenuPresentation,
                        layout: MessageMenuLayout) -> some View {
        let alignment: Alignment = presentation.isOwn ? .trailing : .leading
        let message = presentation.content
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: max(layout.width, presentation.anchor.width), alignment: alignment)

        Group {
            if layout.contentHeight < presentation.anchor.height {
                // As wide as the bubble was, not as the menu is: a scroll view takes the width it
                // is offered, and offered the column's it would re-wrap the message narrower
                // than the one it was lifted from.
                ScrollView(.vertical) { message }
                    .scrollIndicators(.visible)
                    .frame(width: max(layout.width, presentation.anchor.width),
                           height: layout.contentHeight,
                           alignment: .top)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.bubble, style: .continuous))
            } else {
                message
            }
        }
        .shadow(color: .black.opacity(Theme.Backdrop.wash), radius: Theme.Spacing.normal, y: Theme.Spacing.tight)
        // It is a copy of something that is still in the list underneath, so VoiceOver is
        // told about it once — by the menu — and not twice.
        .accessibilityHidden(true)
    }

    private func actions(_ presentation: MessageMenuPresentation,
                         layout: MessageMenuLayout) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(Array(presentation.sections.enumerated()), id: \.element.id) { index, section in
                    ForEach(section.actions) { action in
                        MessageMenuRow(action: action) {
                            close()
                            action.perform()
                        }
                    }

                    if index < presentation.sections.count - 1 {
                        hairline
                    }
                }
            }
            // The menu breathes on all four sides. A first row flush against a 28-point
            // corner is a row the corner cuts into, and a panel whose content starts and stops
            // at its own edge reads as a list that has been cropped rather than as a thing with
            // a shape. Sideways it does something else as well: the grey that follows a finger
            // down the list stops short of the glass, so a pressed row reads as a row and not
            // as the whole panel lighting up.
            .padding(.vertical, Self.listPadding)
            .padding(.horizontal, Self.listInset)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: layout.width)
        .frame(maxHeight: layout.listMaxHeight)
        // Clipped to its own shape before the glass goes under it. A scroll view does not hold
        // its content to the width it was given — it holds it to the width the content asked
        // for — so a long verb in a narrow menu would otherwise be drawn straight out over the
        // conversation on both sides, which is what the emoji panel below was doing.
        .clipShape(Self.panel)
        .navigationGlass(in: Self.panel)
    }

    /// The shape both floating panels are cut to: the list of verbs, and the grid of emoji.
    /// One constant, because two panels side by side with different corners is the sort of
    /// thing nobody can name and everybody can see.
    static let panel = RoundedRectangle(cornerRadius: Theme.Radius.menu, style: .continuous)

    /// The one rule the menu draws, and it is drawn only between *groups* of verbs — never
    /// between two verbs of the same kind.
    ///
    /// Six lines under six items is a table, and a table is read row by row: the eye stops at
    /// every rule to find out what it is separating, six times, on a menu whose whole job is to
    /// be read once. Without them the verbs are a list and the two rules that remain mean
    /// something — "everything above this is about the message, everything below is about the
    /// person who sent it".
    ///
    /// Inset at both ends, so the line stops short of the panel's corners instead of running
    /// into them. Air above and below for the same reason it is inset: a rule crowded against
    /// the rows it divides divides nothing.
    private var hairline: some View {
        Rectangle()
            .fill(.primary.opacity(0.28))
            .frame(height: Theme.Border.hairline)
            .padding(.horizontal, Theme.Spacing.normal)
            .padding(.vertical, Theme.Spacing.close)
    }

    // MARK: - Doing things

    private func react(_ emoji: String, in presentation: MessageMenuPresentation) {
        recent = RecentEmoji.adding(emoji, to: recent)
        close()
        presentation.onReaction(emoji)
    }

    private func close() {
        withAnimation(Theme.Timing.menuOpens) { isPickingEmoji = false }
        presenter.dismiss()
    }

    // MARK: - How tall the parts are before anything is drawn

    /// `MessageMenuLayout` works out where the message goes, and to do that it has to know the
    /// height of what sits above it *before* it is laid out. So the two things that can sit
    /// there are both fixed heights, and this is which one it is.
    private func aboveHeight(for presentation: MessageMenuPresentation) -> CGFloat {
        guard presentation.canReact else { return 0 }
        return isPickingEmoji ? Theme.Size.emojiPanel : Theme.Size.reactionBar
    }

    /// And the list below: a row each, plus a gap for every rule between sections. An estimate
    /// that comes out exact as long as no item wraps to two lines, and if one ever does the
    /// list scrolls, which is the same thing that happens on a short screen.
    private func listHeight(for presentation: MessageMenuPresentation) -> CGFloat {
        let rows = presentation.sections.reduce(0) { $0 + $1.actions.count }
        let rules = max(0, presentation.sections.count - 1)
        return CGFloat(rows) * Theme.Size.menuRow
            + CGFloat(rules) * Self.sectionRule
            + Self.listPadding * 2
    }

    /// The air above the first verb and below the last.
    static let listPadding = Theme.Spacing.close

    /// And at either side of every one of them.
    static let listInset = Theme.Spacing.close

    /// And the height one rule between two groups of them costs: the line, and the air on
    /// either side of it. Named because it is drawn in one place and counted in another, and
    /// the two going out of step is a menu that scrolls by four points for no visible reason.
    static let sectionRule = Theme.Spacing.close * 2 + Theme.Border.hairline
}

// MARK: - One line of the menu

/// A verb, its icon, and the fill that follows the finger.
///
/// The icon leads and the word follows, which is a reversal of what was here first and of what
/// a system menu does. A system menu is opened *by* a row in a list and reads as an extension
/// of it, so it keeps the list's shape — words on the left, symbols tucked away on the right.
/// This one is opened by a message in the middle of the screen, and every messenger anybody
/// has ever used draws it the other way round: the icon first, at a fixed column, so the six
/// or seven shapes make a vertical strip the eye learns in a day and stops reading after that.
/// Faster than words, in the one menu people open twenty times an hour.
/// Internal rather than private: the chat peek draws its verbs with it too — see `ChatPeek`.
struct MessageMenuRow: View {
    let action: MessageMenuAction
    let perform: () -> Void

    var body: some View {
        Button(action: action.manner == .fact ? {} : perform) {
            HStack(spacing: Theme.Spacing.normal) {
                Image(systemName: action.systemImage)
                    .font(action.manner == .fact ? .footnote : .body)
                    .frame(width: Theme.Size.menuIcon)

                Text(action.title)
                    .font(action.manner == .fact ? .footnote : .body)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                Spacer(minLength: 0)
            }
            .foregroundStyle(tint)
            .padding(.horizontal, Theme.Spacing.normal)
            .frame(minHeight: Theme.Size.menuRow)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(MessageMenuRowStyle())
        .disabled(action.manner == .fact)
        // Disabled is how a menu draws a line that only says something — but it is *not* how it
        // should be announced. VoiceOver reading "Sent 12 July, dimmed button" is telling the
        // reader about our layout; the date is the whole of what they asked for.
        .accessibilityRemoveTraits(action.manner == .fact ? .isButton : [])
    }

    private var tint: AnyShapeStyle {
        switch action.manner {
        case .ordinary: AnyShapeStyle(.primary)
        case .destructive: AnyShapeStyle(Color.red)
        case .fact: AnyShapeStyle(.secondary)
        }
    }
}

/// The press: the row fills with a faint grey while the finger is down, and nothing moves.
///
/// Nothing moves on purpose. A menu row that scales under the finger is a row that appears to
/// come *off* the list it is in, and this list is already floating.
private struct MessageMenuRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? AnyShapeStyle(.primary.opacity(0.1)) : AnyShapeStyle(.clear))
            .animation(.smooth(duration: Theme.Timing.chrome / 2), value: configuration.isPressed)
    }
}

// MARK: - The six

/// The bar of quick reactions over the lifted message.
///
/// The same six as the double tap chooses from — see `QuickReaction`, which is the one list —
/// and a "+" at the end for everything else. Capsule, glass, floating: the navigation layer
/// doing exactly what the material is for.
private struct ReactionBar: View {
    let width: CGFloat
    let mine: Set<String>
    let onPick: (String) -> Void
    let onMore: () -> Void

    @Environment(\.accent) private var accent

    /// Seven things in the width of the menu: six emoji and the "+".
    ///
    /// Worked out rather than fixed, because six 44-point circles and a seventh come to more
    /// than a narrow menu is wide — and an `HStack` handed more than it has room for does not
    /// shrink politely, it draws past the capsule it is inside and out over the conversation.
    private var cell: CGFloat {
        let count = CGFloat(QuickReaction.allCases.count + 1)
        return min(Theme.Size.reactionCell, (width - Theme.Spacing.close * 2) / count)
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(QuickReaction.allCases) { reaction in
                EmojiButton(emoji: reaction.key,
                            isMine: mine.contains(reaction.key),
                            size: cell,
                            accent: accent) { onPick(reaction.key) }
                    .frame(maxWidth: .infinity)
            }

            Button(action: onMore) {
                Image(systemName: "plus")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: cell, height: cell)
                    .background(Circle().fill(.primary.opacity(0.08)))
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .accessibilityLabel(Text(Strings.Reactions.more))
        }
        .padding(.horizontal, Theme.Spacing.close)
        .frame(width: width, height: Theme.Size.reactionBar)
        .navigationGlass(in: .capsule)
    }
}
