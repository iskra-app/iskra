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
                        listHeight: listHeight(for: presentation),
                        barWidth: ReactionBar.naturalWidth)

                    // Picked up, not faded in — Telegram's. The arrangement is first drawn with the
                    // message exactly where it stood in the conversation, and springs from there to
                    // where the menu needs it; on closing it springs back into its gap. The bar and
                    // the verbs unfold out of the message on the same value, below. See
                    // `MessageMenuLayout.lift` and `MessageMenuPresenter.isOut`.
                    let away = presenter.isOut ? CGSize.zero : layout.lift

                    ZStack(alignment: .topLeading) {
                        column(presentation, layout: layout)
                            .offset(x: layout.origin.x + away.width, y: layout.origin.y + away.height)
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
            // Darkening on the same spring the message rises on, and clearing as it lands.
            .opacity(presenter.isOut ? 1 : 0)
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
                        // As wide as its own seven cells: wider than the column of verbs, so
                        // the targets are never squeezed, and no wider, so the emoji sit
                        // together as one strip. Slid onto the screen like the panel.
                        ReactionBar(width: layout.barWidth,
                                    mine: presentation.mine,
                                    growsFromTrailing: presentation.isOwn,
                                    isFilled: presenter.isFilled,
                                    onPick: { react($0, in: presentation) },
                                    onMore: {
                                        withAnimation(Theme.Timing.menuOpens) { isPickingEmoji = true }
                                    })
                            .offset(x: layout.barOffset)
                            // Unrolled from the message's own corner, as Telegram's is: the capsule
                            // opens sideways out of the edge the bubble hangs from, and the emoji
                            // in it pop up one after another from that side (`ReactionBar`).
                            .opacity(presenter.isOut ? 1 : 0)
                            .animation(presenter.isOut ? Theme.Timing.menuBarFades : Theme.Timing.menuCloses,
                                       value: presenter.isOut)
                            .scaleEffect(presenter.isOut ? 1 : 0.2,
                                         anchor: presentation.isOwn ? .bottomTrailing : .bottomLeading)
                            .transition(.scale(scale: 0.9, anchor: .bottom).combined(with: .opacity))
                    }
                }

                lifted(presentation, layout: layout)

                // While the emoji panel is open the verbs stand aside. Both at once is a screen
                // with no conversation left on it, and the panel is a detour that ends in a
                // reaction rather than in a menu item.
                if !isPickingEmoji {
                    // Grown out of the message's corner, from almost nothing — Telegram scales its
                    // actions from 0.01 at the edge nearest the bubble and shows them at once (a
                    // 0.05 s fade), so what the eye follows is the list *unfolding* from the message
                    // and not a list fading up somewhere near it. Going, it folds back the same way
                    // and fades with the fold.
                    actions(presentation, layout: layout)
                        .opacity(presenter.isOut ? 1 : 0)
                        .animation(presenter.isOut ? Theme.Timing.menuListShows : Theme.Timing.menuCloses,
                                   value: presenter.isOut)
                        .scaleEffect(presenter.isOut ? 1 : 0.01,
                                     anchor: presentation.isOwn ? .topTrailing : .topLeading)
                        // And standing aside for the emoji panel and back, while the menu is open.
                        .transition(.asymmetric(
                            insertion: .scale(scale: 0.01, anchor: presentation.isOwn ? .topTrailing : .topLeading)
                                .combined(with: .opacity.animation(Theme.Timing.menuListShows)),
                            removal: .scale(scale: 0.01, anchor: presentation.isOwn ? .topTrailing : .topLeading)
                                .combined(with: .opacity)))
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
    /// The same shape, the same colours, the same lines: what the eye follows out of the list
    /// has to be recognisably the thing that was pressed, and Telegram's menu never so much as
    /// re-wraps it. Three things used to change on the way up and none of them does now:
    ///
    /// - **The width.** It was offered the wider of itself and the menu — and a message that
    ///   sizes to what it is offered (a voice message, a reply with its quote) came out stretched
    ///   to the menu's 240 points the moment it was lifted, while one wider than the menu was
    ///   squeezed to it. It is given its own width now, plus a point, as a fixed frame. Not exactly its own: that is the tightest proposal it can still satisfy, where a
    ///   rounding either way costs a line, and the lifted message once came out with its last line
    ///   cut off. A point more can only ever be looser than what the row gave it, so nothing wraps
    ///   that did not wrap before, and nothing is wide enough to un-wrap.
    /// - **The background.** The bubble's fill depends on the room's wallpaper, which the room
    ///   says and the app does not — see `MessageActions.lifted`, which brings the room's
    ///   environment along. And with no wallpaper the fill is a translucent tint, which over the
    ///   curtain is see-through; the lifted bubble carries the page under it (`bubbleIsLifted`).
    /// - **A shadow.** Gone. The scrim already sets the message apart, and a bubble that grows a
    ///   shadow as it is picked up is a bubble that changed.
    ///
    /// Its height is left alone — unless it is taller than the screen has room for. Then it is
    /// given the height `MessageMenuLayout` allows and *scrolls* in it, at full size. It used to
    /// be scaled down to fit instead, and a scaled page of text is a page of text too small to
    /// read; the long message is often the very one somebody opened the menu to copy a piece of.
    @ViewBuilder
    private func lifted(_ presentation: MessageMenuPresentation,
                        layout: MessageMenuLayout) -> some View {
        let alignment: Alignment = presentation.isOwn ? .trailing : .leading
        let width = presentation.anchor.width + 1
        // A *fixed* width, not a maximum. The column around it is the menu's 240 points wide, and
        // a maximum is clamped by what the parent offers — so a message wider than the menu was
        // squeezed to 240 and re-wrapped narrower than the one in the conversation. A fixed frame
        // offers its own width whatever it is offered; a message wider than the column overhangs
        // it on the side away from its anchored edge, which is where it hung in the conversation.
        //
        // And the height it had in the list, fixed too. Asked for its *ideal* height instead
        // (`fixedSize`), a photo answered with less than it is drawn at — it fills the frame it is
        // given, and has no height of its own to ask for — and came up flattened and cut. The row
        // already measured the true height; the point more is the same allowance as the width's.
        let message = presentation.content
            .frame(width: width, height: presentation.anchor.height + 1, alignment: alignment)

        Group {
            if layout.contentHeight < presentation.anchor.height {
                ScrollView(.vertical) { message }
                    .scrollIndicators(.visible)
                    .frame(width: width, height: layout.contentHeight, alignment: .top)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.bubble, style: .continuous))
            } else {
                message
            }
        }
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
            // The verbs land on the glass once it has opened, not with it — see
            // `Theme.Timing.menuFills`. The panel itself is drawn from the first frame.
            .opacity(presenter.isFilled ? 1 : 0)
            .animation(presenter.isFilled ? Theme.Timing.menuContentShows : Theme.Timing.menuCloses,
                       value: presenter.isFilled)
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
struct ReactionBar: View {
    let width: CGFloat
    let mine: Set<String>
    /// Which end the bar unrolls from — the bubble's own edge — and so which emoji pops first.
    let growsFromTrailing: Bool
    /// Whether the emoji are on the capsule yet. The capsule opens empty and they pop onto it
    /// once it has — see `MessageMenuPresenter.isFilled`.
    let isFilled: Bool
    let onPick: (String) -> Void
    let onMore: () -> Void

    @Environment(\.accent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// How long after the bar opens one emoji pops in, by how far it is from the end the bar opens
    /// from, counted from the moment the capsule has opened (`isFilled`). Telegram's spacing
    /// (`ReactionContextNode.animateIn`): a hair after the first, then up to
    /// 0.3 s across the full width — so the row fills like something being laid out, not switched on.
    private func popDelay(_ index: Int, of count: Int) -> Double {
        let fromEdge = growsFromTrailing ? count - 1 - index : index
        return 0.01 + Double(fromEdge) / Double(max(1, count)) * 0.3
    }

    /// One emoji, or the "+", popping into the bar — see `popDelay`.
    private func pops(_ view: some View, index: Int, of count: Int) -> some View {
        view
            .scaleEffect(isFilled || reduceMotion ? 1 : 0.01)
            .opacity(isFilled ? 1 : 0)
            // Popping on, one after another; going, all at once with the glass.
            .animation(isFilled ? Theme.Timing.reactionPops.delay(popDelay(index, of: count)) : Theme.Timing.menuCloses,
                       value: isFilled)
    }

    private static var cells: CGFloat { CGFloat(QuickReaction.allCases.count + 1) }

    /// Seven full cells and the capsule's padding: the width the bar asks for when the screen
    /// has the room. It used to be stretched to the emoji panel's 360 points, which spread the
    /// six across the capsule with a thumb's width of nothing between each pair — a row of
    /// separate buttons rather than one strip. Hugging its cells, the gap between two emoji is
    /// the same on every phone and the strip reads as one thing.
    static var naturalWidth: CGFloat {
        cells * Theme.Size.reactionCell + Theme.Spacing.close * 2
    }

    /// Seven things in the width of the bar: six emoji and the "+".
    ///
    /// Worked out rather than fixed, because on the narrowest screen seven 44-point circles
    /// come to more than there is — and an `HStack` handed more than it has room for does not
    /// shrink politely, it draws past the capsule it is inside and out over the conversation.
    private var cell: CGFloat {
        min(Theme.Size.reactionCell, (width - Theme.Spacing.close * 2) / Self.cells)
    }

    var body: some View {
        let count = QuickReaction.allCases.count + 1

        HStack(spacing: 0) {
            ForEach(Array(QuickReaction.allCases.enumerated()), id: \.element) { index, reaction in
                pops(EmojiButton(emoji: reaction.key,
                                 isMine: mine.contains(reaction.key),
                                 size: cell,
                                 accent: accent) { onPick(reaction.key) },
                     index: index, of: count)
            }

            pops(moreButton, index: count - 1, of: count)
        }
        .padding(.horizontal, Theme.Spacing.close)
        .frame(width: width, height: Theme.Size.reactionBar)
        .navigationGlass(in: .capsule)
    }

    private var moreButton: some View {
        Button(action: onMore) {
            Image(systemName: "plus")
                .font(.body.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: cell, height: cell)
                .background(Circle().fill(.primary.opacity(0.08)))
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(Strings.Reactions.more))
    }
}
