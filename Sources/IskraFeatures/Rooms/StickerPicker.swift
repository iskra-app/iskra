import SwiftUI
import IskraCore
import IskraDesign

/// The stickers the account can send, and the press that sends one — Telegram's sticker panel:
/// the recent row first, then each pack under its name, and a strip of pack pictures along the
/// top that jumps to them.
///
/// A sheet, opened by the button in the composer's field, and not a panel that takes the
/// keyboard's place. That swap is a thing UIKit offers through `inputView` and SwiftUI does not
/// offer at all, and a panel faked underneath the composer would fight the keyboard's own
/// animation every time one replaced the other. Half the screen, as the forward sheet opens, and
/// the whole of it a drag away.
///
/// A tap sends at once and closes the sheet. There is no "selected, now press send": a sticker is
/// a remark, and every messenger that has them sends it on the tap.
struct StickerPicker: View {
    let roomID: String

    /// Sends it. The sheet is gone by the time this is called — see `pick`.
    let onPick: (Sticker) -> Void

    @Environment(\.stickers) private var library
    @Environment(\.accent) private var accent
    @Environment(\.dismiss) private var dismiss

    /// Which tab is lit. Followed by the scroll's jumps, as the emoji panel's is.
    @State private var selected = Self.recentID

    private static let recentID = "recent"

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: Theme.Size.stickerCell), spacing: Theme.Spacing.close)]
    }

    var body: some View {
        #if os(macOS)
        // A popover over the composer on a Mac (`RoomView.stickerPicker`), not a sheet — so none
        // of a sheet's furniture. A title bar with a Close button in it was an empty band across
        // the top of the popover, and the sheet's minimum size, wider than the popover, pushed the
        // grid out past its left edge. Opaque, because the popover's own glass is see-through and
        // the conversation behind it showed between the stickers.
        content
            .background(.background)
            .task { await library?.load(roomID: roomID) }
        #else
        NavigationStack {
            content
                .navigationTitle(Text(Strings.Stickers.title))
                .toolbarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(String(app: Strings.Stickers.close)) { dismiss() }
                    }
                }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task { await library?.load(roomID: roomID) }
        #endif
    }

    @ViewBuilder
    private var content: some View {
        if let library {
            if library.packs.isEmpty && library.recent.isEmpty {
                if library.hasLoaded {
                    empty
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                grid(library)
            }
        } else {
            empty
        }
    }

    /// Nothing to send yet — and the one thing that says how to change that, because this sheet
    /// has no way to: stickers are collected from conversations, a press at a time.
    private var empty: some View {
        VStack(spacing: Theme.Spacing.close) {
            Image(systemName: "face.smiling")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(Strings.Stickers.emptyTitle)
                .font(.headline)
            Text(Strings.Stickers.emptyMessage)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(Theme.Spacing.roomy)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func grid(_ library: StickerLibrary) -> some View {
        ScrollViewReader { scroll in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.Spacing.close) {
                    if !library.recent.isEmpty {
                        section(id: Self.recentID, title: Text(Strings.Stickers.recent),
                                stickers: library.recent, library: library)
                    }
                    ForEach(library.packs) { pack in
                        section(id: pack.id, title: name(of: pack), stickers: pack.stickers, library: library,
                                subscribing: pack.isRoomPack && !library.isSubscribed(pack) ? pack : nil)
                    }
                }
                .padding(.horizontal, Theme.Spacing.roomy)
                .padding(.bottom, Theme.Spacing.roomy)
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                tabs(library)
            }
            .onChange(of: selected) { _, id in
                withAnimation(.smooth(duration: Theme.Timing.chrome)) {
                    scroll.scrollTo(id, anchor: .top)
                }
            }
        }
    }

    /// `subscribing`: a chat's pack the account has not subscribed to — offered here because this
    /// is where somebody meets it, and only here would it otherwise vanish when they leave the chat.
    private func section(id: String, title: Text, stickers: [Sticker], library: StickerLibrary,
                         subscribing pack: StickerPack? = nil) -> some View {
        Section {
            LazyVGrid(columns: columns, spacing: Theme.Spacing.close) {
                ForEach(stickers) { sticker in
                    cell(sticker, library: library)
                }
            }
        } header: {
            HStack {
                title
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if let pack {
                    Button {
                        Task { await library.subscribe(to: pack) }
                    } label: {
                        Label(String(app: Strings.Stickers.subscribe), systemImage: "plus.circle")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(accent.color)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, Theme.Spacing.normal)
            .id(id)
        }
    }

    private func name(of pack: StickerPack) -> Text {
        if pack.isMine { return Text(Strings.Stickers.mine) }
        if pack.isBuiltIn { return Text(Strings.Stickers.builtIn) }
        if let name = pack.name { return Text(name) }
        return Text(Strings.Stickers.roomPack)
    }

    /// One sticker. A tap sends it; a press offers to put it in, or take it out of, the account's
    /// own pack — the same choice a sticker in a conversation offers, so that a sticker found in
    /// somebody's room pack can be kept without first being sent to anyone.
    @ViewBuilder
    private func cell(_ sticker: Sticker, library: StickerLibrary) -> some View {
        if let attachment = sticker.attachment {
            Button {
                pick(sticker)
            } label: {
                StickerView(attachment: attachment, side: Theme.Size.stickerCell)
                    .frame(width: Theme.Size.stickerCell, height: Theme.Size.stickerCell)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(sticker.body))
            .contextMenu {
                if library.isMine(sticker.url) {
                    Button(role: .destructive) {
                        Task { await library.remove(sticker) }
                    } label: {
                        Label(String(app: Strings.Stickers.remove), systemImage: "minus.circle")
                    }
                } else {
                    Button {
                        Task { await library.add(sticker) }
                    } label: {
                        Label(String(app: Strings.Stickers.add), systemImage: "plus.circle")
                    }
                }
            }
        }
    }

    /// The strip of pack pictures. The clock for the recent row, then each pack's own picture —
    /// a sticker standing for its pack is right here, where it is not: every one of them sends.
    private func tabs(_ library: StickerLibrary) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: Theme.Spacing.close) {
                if !library.recent.isEmpty {
                    tab(id: Self.recentID, label: Text(Strings.Stickers.recent)) {
                        Image(systemName: "clock")
                            .font(.body)
                            .foregroundStyle(selected == Self.recentID ? AnyShapeStyle(accent.color)
                                                                       : AnyShapeStyle(.secondary))
                    }
                }
                ForEach(library.packs) { pack in
                    tab(id: pack.id, label: name(of: pack)) {
                        if let icon = pack.icon?.attachment {
                            StickerView(attachment: icon, side: Theme.Size.stickerTab)
                        } else {
                            Image(systemName: "square.grid.2x2")
                        }
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.roomy)
            .padding(.vertical, Theme.Spacing.tight)
        }
        .scrollIndicators(.hidden)
        .background(alignment: .bottom) {
            Rectangle()
                .fill(.primary.opacity(0.1))
                .frame(height: Theme.Border.hairline)
        }
        .background(.background)
    }

    private func tab<Icon: View>(id: String, label: Text, @ViewBuilder icon: () -> Icon) -> some View {
        Button {
            selected = id
        } label: {
            icon()
                .frame(width: Theme.Size.minimumTapTarget, height: Theme.Size.minimumTapTarget)
                .background {
                    if selected == id {
                        RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                            .fill(accent.color.opacity(0.16))
                    }
                }
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected == id ? [.isButton, .isSelected] : .isButton)
    }

    /// Closes first and sends after: the sticker turns up in the conversation the sheet was
    /// covering, and closing on the far side of a round trip would make the tap feel ignored.
    private func pick(_ sticker: Sticker) {
        dismiss()
        onPick(sticker)
    }
}
