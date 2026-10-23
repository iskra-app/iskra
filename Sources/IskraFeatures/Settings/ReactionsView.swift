import SwiftUI
import IskraDesign

/// Choosing what a double tap on a message leaves behind.
///
/// It lived under Appearance for a while, on the grounds that what a conversation looks like is
/// one subject. It is not: the colour of a bubble is something you look at, and the emoji a
/// double tap sends is something the app *does* on your behalf when you touch a message. A
/// person who wants to change it goes looking for the word "Reactions", and while it was folded
/// into Appearance there was nothing on the settings root by that name to find.
///
/// The choice is any emoji, not one of six. It used to be one of six — the same six the menu bar
/// offers — and the restriction had no reason behind it beyond the type the setting happened to
/// be stored as: somebody whose reaction is 🔥 had to settle for one of somebody else's. So a
/// row of five of them is still here, because it is one tap and it is what most people want, and behind
/// the "+" at the end of it is the whole catalogue — the *same* `EmojiPanel` the context menu
/// opens, so this screen can never offer a reaction a message cannot be given.
///
/// The choice is written straight to `@AppStorage`, so there is no "done": the next double tap in
/// any conversation already sends the new one.
struct ReactionsView: View {
    /// What a double tap on a message leaves behind — see `QuickReaction`.
    ///
    /// A `String`, and any emoji at all. The five in `QuickReaction` are the shortcuts.
    @AppStorage(QuickReaction.storageKey) private var reaction = QuickReaction.defaultKey

    /// The emoji reached for lately, shown at the top of the picker. The same list the menu
    /// keeps — see `RecentEmoji` — and read only: choosing a quick reaction is setting a
    /// preference, not reacting to anything, so it does not push anything onto the list.
    @AppStorage(RecentEmoji.storageKey) private var recent = ""

    /// Whether the whole catalogue is up.
    @State private var isPickingEmoji = false

    /// The colour the chosen one sits in. Read from the environment rather than from
    /// `@AppStorage`, because the environment is what the rest of the app is actually painted in.
    @Environment(\.accent) private var accent

    /// Sized by the emoji, not by a column count — the five shortcuts and the "+" are one
    /// row on a Mac and on a phone, and neither has to be spelled out.
    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: Theme.Size.swatch), spacing: Theme.Spacing.roomy)]
    }

    /// The emoji across the row: the five of `QuickReaction`, and the "+" after them makes six —
    /// one row on a phone, where six and a "+" wrapped the "+" onto a line of its own.
    ///
    /// When the emoji in force is not one of the five it takes the fifth place, lit. Without that
    /// the screen would show five unlit circles to somebody who has chosen 🔥 — a setting with no
    /// visible value, on the screen that exists to show it — and adding it as a seventh would
    /// wrap the row again.
    private var row: [String] {
        let shortcuts = QuickReaction.keys
        return shortcuts.contains(reaction) ? shortcuts : shortcuts.dropLast() + [reaction]
    }

    var body: some View {
        Form {
            Section {
                LazyVGrid(columns: columns, spacing: Theme.Spacing.roomy) {
                    ForEach(row, id: \.self) { emoji in
                        swatch(emoji)
                    }

                    more
                }
                .padding(.vertical, Theme.Spacing.close)
            } header: {
                Text(Strings.Reactions.quick)
            } footer: {
                Text(Strings.Reactions.quickHelp)
            }

            // The other thing people send instead of words — the screen is "Stickers & reactions".
            StickerSettingsSections()
        }
        .formStyle(.groupedRows)
        .navigationTitle(Text(Strings.Settings.reactions))
        .toolbarTitleDisplayMode(.inline)
        .pageSheet(isPresented: $isPickingEmoji) { picker }
    }

    /// One emoji, pressable, lit when it is the one in force.
    private func swatch(_ emoji: String) -> some View {
        Button {
            withAnimation(.smooth(duration: Theme.Timing.reaction)) { reaction = emoji }
        } label: {
            Text(emoji)
                .font(.title2)
                .frame(width: Theme.Size.swatch, height: Theme.Size.swatch)
                // The chosen one sits in a disc of the app's colour. The unchosen ones sit on
                // nothing at all — an emoji is legible against the sheet it is on, and a row of
                // grey circles would read as buttons that are all switched off.
                .background {
                    if emoji == reaction {
                        Circle().fill(accent.color.opacity(0.18))
                        Circle().strokeBorder(accent.color, lineWidth: Theme.Border.hairline)
                    }
                }
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        // VoiceOver reads an emoji by its own name, which is better than anything we would
        // write for it; what it cannot say is which one is currently in force.
        .accessibilityAddTraits(emoji == reaction ? [.isButton, .isSelected] : .isButton)
    }

    /// Everything that is not one of the five. The same plus sign, in the same place, as the one
    /// on the bar above a lifted message — it opens the same picker, and that is the point of it
    /// looking identical.
    private var more: some View {
        Button {
            isPickingEmoji = true
        } label: {
            Image(systemName: "plus")
                .font(.body.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: Theme.Size.swatch, height: Theme.Size.swatch)
                .background(Circle().fill(.primary.opacity(0.08)))
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(Strings.Reactions.more))
    }

    /// The catalogue, in a sheet of its own.
    ///
    /// A sheet rather than a panel hanging off the row, because there is nothing here for it to
    /// hang off: over a message the picker is anchored to the message, and on a settings screen
    /// the anchor would be a table row that scrolls. The panel is asked for without its glass —
    /// see `EmojiPanel.isFloating` — since a sheet is already the floating surface.
    ///
    /// `mine` is empty on purpose. On a message that set is "the reactions you have already
    /// left", and it lights them so that pressing one again visibly takes it back. Here there is
    /// nothing to take back: the one lit emoji is the *setting*, and it is lit in the row above.
    private var picker: some View {
        NavigationStack {
            GeometryReader { proxy in
                EmojiPanel(width: proxy.size.width,
                           mine: [],
                           recent: RecentEmoji.list(from: recent),
                           onPick: { emoji in
                               reaction = emoji
                               isPickingEmoji = false
                           },
                           isFloating: false,
                           height: proxy.size.height)
            }
            .navigationTitle(Text(Strings.Reactions.more))
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(app: Strings.Reactions.cancel)) { isPickingEmoji = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
