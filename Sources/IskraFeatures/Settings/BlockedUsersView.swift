import SwiftUI
import IskraCore
import IskraDesign

/// The people the user has blocked, and the way to let them back. Reached from settings; the list
/// itself is `BlockStore`, kept live by a subscription, so a block made from a message's menu shows
/// here the moment it takes.
///
/// Only Matrix IDs are shown, not names: the block list the SDK hands back is a list of IDs, and
/// resolving each to a display name would mean a fetch per row for a screen nobody visits often. The
/// ID is the thing that is unambiguous anyway — a display name can be anyone's.
struct BlockedUsersView: View {
    let store: BlockStore

    var body: some View {
        List {
            ForEach(store.blockedUserIDs, id: \.self) { userID in
                HStack {
                    Text(userID)
                        .font(.body)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: Theme.Spacing.normal)
                    Button(String(app: Strings.Settings.unblock)) {
                        Task { await store.unblock(userID: userID) }
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                }
            }
        }
        .navigationTitle(Text(Strings.Settings.blocked))
        .toolbarTitleDisplayMode(.inline)
        .failureAlert(Bindable(store).failure)
        .overlay { emptyState }
    }

    @ViewBuilder
    private var emptyState: some View {
        if store.blockedUserIDs.isEmpty {
            ContentUnavailableView(String(app: Strings.Settings.blockedEmptyTitle),
                                   systemImage: "hand.raised",
                                   description: Text(Strings.Settings.blockedEmptyMessage))
        }
    }
}
