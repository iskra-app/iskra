import SwiftUI
import IskraCore
import IskraDesign

/// Searching inside the open conversation. A field and a list of hits; tapping one closes the sheet
/// and takes the reader to that message — the same jump a reply or a global-search result makes.
///
/// It reuses `SearchHit` and reads exactly like the room list's search results, because it is the
/// same kind of answer to a narrower question: not "which chat holds this" but "where in this chat".
struct RoomSearchView: View {
    let store: RoomSearchStore
    var onOpen: (String) -> Void

    @State private var query = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(store.hits) { hit in
                    Button {
                        onOpen(hit.id)
                    } label: {
                        VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                            HStack {
                                Text(hit.senderName)
                                    .font(.subheadline.weight(.semibold))
                                Spacer(minLength: 0)
                                Text(RoomTimestamp.label(for: hit.timestamp))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Text(hit.excerpt)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.plain)
            .overlay { emptyState }
            .searchable(text: $query, prompt: Text(Strings.Room.searchPrompt))
            // Scrolling the results puts the keyboard away — it covers half of them otherwise.
            .scrollDismissesKeyboard(.immediately)
            .onChange(of: query) { _, text in
                store.search(text)
            }
            .navigationTitle(Text(Strings.Room.searchInChat))
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(app: Strings.Room.searchClose)) { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if store.foundNothing, !store.isSearching {
            ContentUnavailableView.search(text: query)
        } else if store.hits.isEmpty, !store.isSearching {
            // Before the first search: a quiet prompt rather than a blank sheet.
            ContentUnavailableView(String(app: Strings.Room.searchInChat),
                                   systemImage: "magnifyingglass")
        }
    }
}
