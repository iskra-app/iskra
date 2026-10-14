import SwiftUI
import IskraCore
import IskraDesign

/// The sticker half of Settings → Stickers & reactions: which packs the sheet offers, the packs
/// the account has subscribed to, the account's own stickers, and the recent row. Sections, not a
/// screen — they sit in `ReactionsView`'s form, under the quick reaction.
///
/// Everything here but the two switches is the *account's* — MSC2545 account data, the same lists
/// Element and Cinny read — so a sticker taken out here is gone from those too, and the screen
/// says nothing it would have to take back: each change is written as it is made.
struct StickerSettingsSections: View {
    @Environment(\.stickers) private var library

    @AppStorage(StickerSettings.showsBuiltInKey) private var showsBuiltIn = true
    @AppStorage(StickerSettings.showsRoomPackKey) private var showsRoomPack = true

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: Theme.Size.stickerCell), spacing: Theme.Spacing.close)]
    }

    var body: some View {
        Group {
            Section {
                Toggle(isOn: $showsBuiltIn) {
                    Label(Strings.Stickers.Settings.builtIn, systemImage: "sparkles")
                }
                .accentControl()
                Toggle(isOn: $showsRoomPack) {
                    Label(Strings.Stickers.Settings.roomPacks, systemImage: "bubble.left.and.bubble.right")
                }
                .accentControl()
            } header: {
                Text(Strings.Stickers.Settings.sheetSection)
            } footer: {
                Text(Strings.Stickers.Settings.roomPacksHelp)
            }

            if let library {
                subscriptions(library)
                mine(library)
                recent(library)
            }
        }
        .task { await library?.load(roomID: nil) }
        .failureAlert(Binding(get: { library?.failure }, set: { library?.failure = $0 }))
    }

    @ViewBuilder
    private func subscriptions(_ library: StickerLibrary) -> some View {
        let packs = library.packs.filter { $0.isRoomPack && library.isSubscribed($0) }
        if !packs.isEmpty {
            Section {
                ForEach(packs) { pack in
                    packRow(pack)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                Task { await library.unsubscribe(from: pack) }
                            } label: {
                                Label(String(app: Strings.Stickers.Settings.unsubscribe), systemImage: "minus.circle")
                            }
                            // Red by hand: a swipe button takes the screen's tint, and on the mono
                            // accent that is white.
                            .tint(.red)
                        }
                        // A Mac has no swipe to find it by.
                        .contextMenu {
                            Button(role: .destructive) {
                                Task { await library.unsubscribe(from: pack) }
                            } label: {
                                Label(String(app: Strings.Stickers.Settings.unsubscribe), systemImage: "minus.circle")
                            }
                        }
                }
            } header: {
                Text(Strings.Stickers.Settings.subscriptionsSection)
            } footer: {
                Text(Strings.Stickers.Settings.subscriptionsHelp)
            }
        }
    }

    private func packRow(_ pack: StickerPack) -> some View {
        HStack(spacing: Theme.Spacing.normal) {
            Group {
                if let icon = pack.icon?.attachment {
                    StickerView(attachment: icon, side: Theme.Size.stickerTab)
                } else {
                    Image(systemName: "square.grid.2x2")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: Theme.Size.stickerTab, height: Theme.Size.stickerTab)

            VStack(alignment: .leading, spacing: Theme.Spacing.withinRun) {
                if let name = pack.name {
                    Text(verbatim: name)
                } else {
                    Text(Strings.Stickers.roomPack)
                }
                Text(Strings.Stickers.Settings.count(pack.stickers.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The account's own stickers, a press on one to take it out — the same press that does it in
    /// the sheet and on a sticker in a chat.
    private func mine(_ library: StickerLibrary) -> some View {
        Section {
            if let pack = library.packs.first(where: \.isMine) {
                LazyVGrid(columns: columns, spacing: Theme.Spacing.close) {
                    ForEach(pack.stickers) { sticker in
                        if let attachment = sticker.attachment {
                            StickerView(attachment: attachment, side: Theme.Size.stickerCell)
                                .frame(width: Theme.Size.stickerCell, height: Theme.Size.stickerCell)
                                .contentShape(.rect)
                                .accessibilityLabel(Text(sticker.body))
                                .contextMenu {
                                    Button(role: .destructive) {
                                        Task { await library.remove(sticker) }
                                    } label: {
                                        Label(String(app: Strings.Stickers.remove), systemImage: "minus.circle")
                                    }
                                }
                        }
                    }
                }
                .padding(.vertical, Theme.Spacing.tight)
            } else if library.hasLoaded {
                Text(Strings.Stickers.emptyMessage)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity)
            }
        } header: {
            Text(Strings.Stickers.mine)
        } footer: {
            Text(Strings.Stickers.Settings.mineHelp)
        }
    }

    private func recent(_ library: StickerLibrary) -> some View {
        Section {
            Button(role: .destructive) {
                Task { await library.clearRecent() }
            } label: {
                Text(Strings.Stickers.Settings.clearRecent)
            }
            .disabled(library.recent.isEmpty)
        } footer: {
            Text(Strings.Stickers.Settings.clearRecentHelp)
        }
    }
}
