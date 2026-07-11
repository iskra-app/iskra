import SwiftUI
import IskraCore
import IskraDesign

/// The list of conversations.
public struct RoomListView: View {
    let session: UserSession
    @Binding var selectedRoomID: String?

    @State private var searchText = ""

    public init(session: UserSession, selectedRoomID: Binding<String?>) {
        self.session = session
        _selectedRoomID = selectedRoomID
    }

    public var body: some View {
        List(selection: $selectedRoomID) {
            if isSearching {
                searchResults
            } else {
                rooms
            }
        }
        .listStyle(.plain)
        .navigationTitle(Text(Strings.RoomList.title))
        .searchable(text: $searchText, prompt: Text(Strings.RoomList.searchPrompt))
        .onChange(of: searchText) { _, query in
            session.search.search(query)
        }
        .overlay {
            emptyState
        }
    }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    @ViewBuilder
    private var rooms: some View {
        ForEach(session.roomList.rooms) { room in
            RoomRow(room: room)
                .tag(room.id)
        }
    }

    @ViewBuilder
    private var searchResults: some View {
        ForEach(session.search.hits) { hit in
            Button {
                selectedRoomID = hit.roomID
            } label: {
                VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                    Text(hit.senderName)
                        .font(.subheadline.weight(.semibold))
                    Text(hit.excerpt)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if isSearching, session.search.foundNothing, !session.search.isSearching {
            ContentUnavailableView.search(text: searchText)
        } else if !isSearching, session.roomList.rooms.isEmpty {
            if session.roomList.isLoadingInitialRooms {
                ProgressView { Text(Strings.RoomList.loading) }
            } else {
                ContentUnavailableView(String(app: Strings.RoomList.emptyTitle),
                                       systemImage: "bubble.left.and.bubble.right",
                                       description: Text(Strings.RoomList.emptyMessage))
            }
        }
    }
}

/// One conversation in the list.
private struct RoomRow: View {
    let room: RoomSummary

    var body: some View {
        HStack(spacing: Theme.Spacing.normal) {
            Avatar(name: room.name, url: room.avatarURL, size: Theme.Size.avatar)

            VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                HStack(spacing: Theme.Spacing.tight) {
                    Text(room.name)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)

                    // A closed lock is the only encryption vocabulary on this screen.
                    if room.privacy == .protected {
                        Image(systemName: "lock.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(Text(Strings.RoomList.privateChat))
                    }

                    Spacer(minLength: 0)

                    if let date = room.lastActivity {
                        Text(date, format: .relative(presentation: .numeric, unitsStyle: .narrow))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: Theme.Spacing.close) {
                    Text(room.lastMessage ?? " ")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Spacer(minLength: 0)

                    if room.hasUnread {
                        // A count, not a sentence — but still formatted for the locale
                        // rather than interpolated, so the digits are the right ones.
                        Text(room.unreadCount, format: .number)
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(room.isMentioned ? Color.red : Color.accentColor,
                                        in: Capsule())
                    }
                }
            }
        }
        .padding(.vertical, Theme.Spacing.tight)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    /// One sentence, so VoiceOver reads a row as a thought rather than as a pile of
    /// fragments.
    private var accessibilityLabel: String {
        var parts = [room.name]
        if room.privacy == .protected {
            parts.append(String(app: Strings.RoomList.privateChat))
        }
        if let message = room.lastMessage { parts.append(message) }
        if room.isMentioned {
            parts.append(String(app: Strings.RoomList.mentions(room.mentionCount)))
        } else if room.hasUnread {
            parts.append(String(app: Strings.RoomList.unread(room.unreadCount)))
        }
        return parts.joined(separator: ", ")
    }
}

/// A round avatar, falling back to initials when there is no picture.
struct Avatar: View {
    let name: String
    let url: String?
    let size: CGFloat

    var body: some View {
        Circle()
            .fill(.quaternary)
            .frame(width: size, height: size)
            .overlay {
                Text(initials)
                    .font(.system(size: size * 0.4, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .accessibilityHidden(true)
    }

    private var initials: String {
        let words = name.split(separator: " ").prefix(2)
        return words.compactMap(\.first).map(String.init).joined().uppercased()
    }
}
