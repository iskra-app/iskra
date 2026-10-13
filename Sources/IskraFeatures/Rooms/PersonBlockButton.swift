import SwiftUI
import IskraCore
import IskraDesign

/// "Block User" — or "Unblock User" — at the foot of a person's page, wherever that page was
/// reached from: a personal chat's info, or a name in a group. One button, so the two screens
/// that are now one screen cannot drift apart on the one act that matters most on it.
///
/// This is the *account's* block, Matrix's ignore (`BlockStore`): it follows the account to every
/// device and stops this person's messages arriving anywhere. It is not a room's ban, which is
/// `Room.Manage.block` and belongs to whoever runs a group.
struct PersonBlockButton: View {
    let userID: String
    let name: String

    @Environment(\.blockStore) private var blockStore
    @Environment(\.currentUserID) private var currentUserID
    @Environment(\.isOffline) private var isOffline

    @State private var isConfirming = false

    var body: some View {
        if let blockStore, userID != currentUserID {
            let isBlocked = blockStore.isBlocked(userID)

            Button(role: isBlocked ? nil : .destructive) {
                if isBlocked {
                    Task { await blockStore.unblock(userID: userID) }
                } else {
                    isConfirming = true
                }
            } label: {
                Label(String(app: isBlocked ? Strings.Profile.unblockUser : Strings.Profile.blockUser),
                      systemImage: isBlocked ? "hand.raised.slash" : "hand.raised")
            }
            .disabled(isOffline)
            .confirmationDialog(Text(Strings.Message.Menu.blockConfirm(name)),
                                isPresented: $isConfirming,
                                titleVisibility: .visible) {
                Button(String(app: Strings.Profile.blockUser), role: .destructive) {
                    Task { await blockStore.block(userID: userID) }
                }
            } message: {
                Text(Strings.Message.Menu.blockConfirmMessage)
            }
        }
    }
}
