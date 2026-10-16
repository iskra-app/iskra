import AppIntents
import IskraCore
import IskraDesign
import SwiftUI
import WidgetKit

/// The people you write to, on the home screen: four faces in a small widget, eight in a medium one,
/// each a tap away from its chat.
///
/// Everything it shows comes from the App Group — the directory the app writes (`ChatDirectory`)
/// and the pictures it downloads (`DirectoryFaces`). It has no session and asks no server anything.
/// The app tells it to redraw only when something it shows has changed (`WidgetRefresh`), so its
/// timeline is a single entry that never expires.
struct FavouritesWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: WidgetChats.kind, intent: SelectChatsIntent.self,
                               provider: FavouritesProvider()) { entry in
            FavouritesView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName(Text(CoreStrings.Widget.favouritesName))
        .description(Text(CoreStrings.Widget.favouritesDescription))
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct FavouritesEntry: TimelineEntry {
    enum Content {
        case chats([Face])
        /// The app lock is on — see `AppLock.isEnabled(defaults:)`.
        case locked
        /// Nobody signed in, or nothing written yet.
        case empty
    }

    struct Face: Identifiable {
        let chat: ChatEntity
        let name: String
        let file: URL?
        let seed: String
        let hasUnread: Bool

        var id: String { chat.id }
    }

    let date: Date
    let content: Content
}

struct FavouritesProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> FavouritesEntry {
        FavouritesEntry(date: .now, content: .chats([]))
    }

    func snapshot(for configuration: SelectChatsIntent, in context: Context) async -> FavouritesEntry {
        entry(for: configuration, family: context.family)
    }

    func timeline(for configuration: SelectChatsIntent, in context: Context) async -> Timeline<FavouritesEntry> {
        // Said to the app, which cannot read a widget's configuration, so it knows whose pictures
        // are worth fetching — see `DirectoryFaces.wanted`.
        WidgetChats.recordChosen(configuration.chats?.map(\.id) ?? [])
        return Timeline(entries: [entry(for: configuration, family: context.family)], policy: .never)
    }

    private func entry(for configuration: SelectChatsIntent, family: WidgetFamily) -> FavouritesEntry {
        let defaults = ChatDirectory.sharedDefaults
        // With the lock on, the widget cannot know who is looking at it — so it shows nobody.
        guard !AppLock.isEnabled(defaults: defaults) else { return FavouritesEntry(date: .now, content: .locked) }

        let entries = ChatDirectory.directory(from: defaults)
        guard !entries.isEmpty else { return FavouritesEntry(date: .now, content: .empty) }

        let showsAccount = Set(entries.compactMap(\.accountID)).count > 1
        let folder = try? DirectoryFaces.folder()
        let chosen = WidgetChats.fill(entries,
                                      chosen: configuration.chats?.map(\.id) ?? [],
                                      count: family == .systemSmall ? 4 : WidgetChats.largest,
                                      account: ChatDirectory.widgetAccountID(in: defaults))
        let faces = chosen.map { entry in
            FavouritesEntry.Face(chat: ChatEntity(entry, showsAccount: showsAccount),
                                 name: entry.name,
                                 file: DirectoryFaces.url(for: entry, in: folder),
                                 seed: entry.avatarSeed ?? entry.id,
                                 hasUnread: (entry.unreadCount ?? 0) > 0)
        }
        return FavouritesEntry(date: .now, content: .chats(faces))
    }
}

struct FavouritesView: View {
    let entry: FavouritesEntry

    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch entry.content {
        case let .chats(faces):
            grid(faces)
        case .locked:
            message(CoreStrings.Widget.locked, symbol: "lock.fill")
        case .empty:
            message(CoreStrings.Widget.empty, symbol: "bubble.left.and.bubble.right")
        }
    }

    private var columns: Int { family == .systemSmall ? 2 : 4 }

    private func grid(_ faces: [FavouritesEntry.Face]) -> some View {
        Grid(horizontalSpacing: Theme.Spacing.close, verticalSpacing: Theme.Spacing.close) {
            ForEach(0..<2, id: \.self) { row in
                GridRow {
                    ForEach(0..<columns, id: \.self) { column in
                        let index = row * columns + column
                        if index < faces.count {
                            cell(faces[index])
                        } else {
                            // An empty place opens the app, which is all a tap on nothing can mean.
                            Circle()
                                .fill(.quaternary)
                                .frame(width: Theme.Size.widgetFace, height: Theme.Size.widgetFace)
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
        }
    }

    /// One face and its name, opening its chat — and switching account first if the chat is another
    /// account's.
    ///
    /// A plain link where the system allows one, because a link *is* the request: the app is opened
    /// with the chat in the URL and nothing can race it. A small widget allows no links — it is one
    /// tap target to WidgetKit — so there it is `OpenChatIntent`, whose request the app is told about
    /// across processes (`OpenRequestSignal`).
    @ViewBuilder
    private func cell(_ face: FavouritesEntry.Face) -> some View {
        if family == .systemSmall {
            Button(intent: OpenChatIntent(chat: face.chat)) { label(face) }
                .buttonStyle(.plain)
        } else {
            Link(destination: AppEnvironment.openChatURL(roomID: face.chat.roomID,
                                                         accountID: face.chat.accountID)) {
                label(face)
            }
        }
    }

    private func label(_ face: FavouritesEntry.Face) -> some View {
        VStack(spacing: Theme.Spacing.tight) {
            WidgetFace(file: face.file, seed: face.seed, name: face.name)
                .overlay(alignment: .topTrailing) {
                    if face.hasUnread {
                        Circle()
                            .fill(.tint)
                            .frame(width: Theme.Size.unreadDot, height: Theme.Size.unreadDot)
                            .widgetAccentable()
                    }
                }
            Text(verbatim: face.name)
                .font(.caption2)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity)
        // The whole cell is the target — face, name and the space between — whatever is drawn in it.
        .contentShape(.rect)
    }

    private func message(_ text: LocalizedStringResource, symbol: String) -> some View {
        VStack(spacing: Theme.Spacing.close) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(text)
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
    }
}
