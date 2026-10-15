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

    @Environment(\.accent) private var accent
    @Environment(\.colorScheme) private var colorScheme

    /// One pill under the selected tab, which slides to the next — rather than one pill going out
    /// and another coming in.
    @Namespace private var pill

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
        let isSelected = selection == id
        return Button {
            withAnimation(Theme.Timing.folderSwitches) { selection = id }
        } label: {
            HStack(spacing: Theme.Spacing.tight) {
                Text(title)
                    .lineLimit(1)
                if unread > 0 {
                    Text(unread, format: .number)
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .padding(.horizontal, Theme.Spacing.tight)
                        .frame(minWidth: Theme.Size.unreadDot * 2)
                        .background(isSelected ? AnyShapeStyle(.background.opacity(0.3)) : AnyShapeStyle(.quaternary),
                                    in: Capsule())
                }
            }
            .font(.subheadline.weight(isSelected ? .semibold : .regular))
            .padding(.horizontal, Theme.Spacing.normal)
            .padding(.vertical, Theme.Spacing.close)
            .foregroundStyle(isSelected ? accent.foreground(in: colorScheme) : AnyShapeStyle(.primary))
            .background {
                if isSelected {
                    Capsule()
                        .fill(accent.solid(in: colorScheme))
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
