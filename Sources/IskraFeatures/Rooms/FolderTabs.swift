import SwiftUI
import IskraCore
import IskraDesign

/// The folders, as tabs over the chat list — "All" first, then each folder with how many of its
/// chats have something unread. Telegram's strip, on glass, because it floats over the list like
/// the rest of the navigation layer.
///
/// Nothing at all when the account has no folders: a strip with one tab in it is a control that
/// does nothing.
struct FolderTabs: View {
    let folders: [ChatFolder]
    let rooms: [RoomSummary]
    let archived: [RoomSummary]
    @Binding var selection: String
    let onEdit: () -> Void

    /// One pill under the selected tab, which slides to the next — rather than one pill going out
    /// and another coming in.
    @Namespace private var pill

    /// Where the pill is drawn — the selection, one frame late, on purpose.
    ///
    /// A tap changes two things: which chats the list shows, and where the pill is. The first is a
    /// rebuild of the whole list, and done in the same frame as the start of the slide it took that
    /// frame and the next few with it — the slide ran at what looked like half the frame rate. So
    /// the list changes at once, unanimated, and the pill starts moving on the frame after, when
    /// the heavy part is already over.
    @State private var shown: String?

    var body: some View {
        ScrollViewReader { scroll in
            ScrollView(.horizontal) {
                HStack(spacing: Theme.Spacing.tight) {
                    tab(id: "", title: String(app: Strings.Folders.all),
                        unread: rooms.filter(\.hasUnread).count)
                    ForEach(folders) { folder in
                        tab(id: folder.id, title: folder.name,
                            unread: folder.rooms(from: rooms, archived: archived).filter(\.hasUnread).count)
                    }
                }
                .padding(Theme.Spacing.tight)
            }
            .scrollIndicators(.hidden)
            .navigationGlass(in: .capsule)
            .padding(.horizontal, Theme.Spacing.normal)
            .padding(.vertical, Theme.Spacing.tight)
            .onChange(of: selection) { _, id in
                if shown != id, shown != nil {
                    Task { @MainActor in
                        await Task.yield()
                        withAnimation(Theme.Timing.folderSwitches) { shown = id }
                    }
                }
                withAnimation(.smooth(duration: Theme.Timing.chrome)) { scroll.scrollTo(id, anchor: .center) }
            }
        }
        .contextMenu {
            Button(action: onEdit) {
                Label(String(app: Strings.Folders.title), systemImage: "folder.badge.gearshape")
            }
        }
    }

    private func tab(id: String, title: String, unread: Int) -> some View {
        let isSelected = (shown ?? selection) == id
        return Button {
            guard selection != id else { return }
            selection = id
            Task { @MainActor in
                await Task.yield()
                withAnimation(Theme.Timing.folderSwitches) { shown = id }
            }
        } label: {
            HStack(spacing: Theme.Spacing.tight) {
                Text(title)
                    .lineLimit(1)
                if unread > 0 {
                    Text(unread, format: .number)
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .padding(.horizontal, Theme.Spacing.tight)
                        .frame(minWidth: Theme.Size.unreadDot * 2)
                        .background(.quaternary, in: Capsule())
                }
            }
            .font(.subheadline.weight(isSelected ? .semibold : .regular))
            .padding(.horizontal, Theme.Spacing.normal)
            .padding(.vertical, Theme.Spacing.close)
            .foregroundStyle(.primary)
            // Grey, and only just there: the tab is where you are, not a button to press — the
            // accent is for what can be pressed. A plain colour, not a hierarchical style, which
            // glass would turn vibrant (see `AccentTheme.solid`).
            .background {
                if isSelected {
                    Capsule()
                        .fill(Color.gray.opacity(Theme.Opacity.selectedTab))
                        .matchedGeometryEffect(id: "selected", in: pill)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .id(id)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}
