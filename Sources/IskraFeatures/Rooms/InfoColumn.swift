#if os(macOS)
import SwiftUI
import IskraCore
import IskraDesign

/// The chat's info as a column on the right of a Mac window — the web client's — held at the root
/// of the conversation's half of the window rather than by the conversation.
///
/// Two reasons it lives up there. An inspector attached to a view *inside* a navigation stack sits
/// under the window's toolbar: a band of empty title bar over the column, and the column's own
/// buttons put in the conversation's half of the toolbar, beside the chat's header. Attached to the
/// stack from outside, it runs the full height of the window and its toolbar items stand over it.
/// And the column outlives the conversation: left open, it stays open — in the next chat, and
/// after a relaunch — which a column owned by one `RoomView` could not.
///
/// The room on screen hands it what to show (`attach`), and takes it back when it goes (`detach`);
/// whether the column is open is the user's, remembered on the device.
@MainActor
@Observable
final class InfoColumn {
    private static let openKey = "infoColumn.isOpen"

    /// Whether the user left the column open. Remembered across chats and launches.
    var isOpen: Bool = UserDefaults.standard.bool(forKey: InfoColumn.openKey) {
        didSet { UserDefaults.standard.set(isOpen, forKey: Self.openKey) }
    }

    /// What the column shows: the open chat's info, built by that chat.
    private(set) var content: AnyView?
    private var owner: UUID?

    /// Open, and with something in it.
    var isPresented: Bool { isOpen && content != nil }

    func attach(_ content: AnyView, owner: UUID) {
        self.content = content
        self.owner = owner
    }

    /// Takes the content away if it is still this owner's — a chat that goes after the next one
    /// arrived must not empty the column the next one just filled. The column stays as open or as
    /// closed as the user left it.
    func detach(owner: UUID) {
        guard self.owner == owner else { return }
        content = nil
        self.owner = nil
    }
}

/// What a chat puts in the column: its info screen, in a stack of its own for what that opens, with
/// the pencil and the way out over it. The buttons are there only while the column is open — the
/// inspector keeps its content alive after it closes, and a pencil was once left in the title bar
/// over nothing.
struct RoomInfoColumn<Info: View>: View {
    let details: RoomDetailsStore
    let onEdit: () -> Void
    let onClose: () -> Void
    @ViewBuilder let info: Info

    @Environment(\.infoColumn) private var column

    var body: some View {
        NavigationStack { info }
            .toolbar {
                RoomInfoColumnToolbar(details: details,
                                      isShown: column?.isPresented ?? false,
                                      onEdit: onEdit,
                                      onClose: onClose)
            }
    }
}

extension EnvironmentValues {
    /// The window's info column — see `InfoColumn`. Nil outside the conversation's half of a Mac
    /// window, where there is no column.
    @Entry var infoColumn: InfoColumn?
}

extension View {
    /// Hangs the info column on the conversation's half of the window — from outside its stack.
    func infoColumn(_ column: InfoColumn) -> some View {
        inspector(isPresented: Binding(get: { column.isPresented },
                                       set: { if !$0 { column.isOpen = false } })) {
            column.content
                .inspectorColumnWidth(min: Theme.Size.infoColumnMinimum,
                                      ideal: Theme.Size.infoColumnIdeal,
                                      max: Theme.Size.infoColumnMaximum)
        }
        .environment(\.infoColumn, column)
    }
}
#endif
