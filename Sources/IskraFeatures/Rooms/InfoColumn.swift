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

    /// The minimum frame to put on the chat, so that the window's least width comes out as
    /// `Theme.Size.windowMinimum` with the column open and shut alike.
    ///
    /// Shut, the chat takes the column's width too. Open, it is asked for a column's width *less*
    /// than it will get: SwiftUI counts an inspector on a split view twice in the window's least
    /// width — once in the conversation column's minimum and again as itself (measured with
    /// `Iskra --probe-resize`) — and the chat's own minimum is where that second count is paid
    /// for. Asked for the full `conversationMinimum` there, the window needed a column more than it
    /// has, and the column could not open in the narrowest window.
    var conversationMinimumWidth: CGFloat {
        isPresented
            ? Theme.Size.conversationMinimum.width - Theme.Size.sideColumn
            : Theme.Size.windowMinimum - Theme.Size.sideColumn
    }

    /// Opens the column — first making room for it, if the window has none.
    ///
    /// The column takes its width out of the conversation and leaves the window as it is. But a
    /// window already at its narrowest has no width to give, and then SwiftUI widened the window
    /// itself, animated, in jerks, a frame at a time. So in that one case the window is widened
    /// here first, at once and by exactly what is missing, and the column then opens into it.
    func open() {
        makeRoom()
        isOpen = true
    }

    private func makeRoom() {
        // The window is never narrower than `windowMinimum`, which has room for the column — but a
        // window saved narrower by an earlier build is, and a column opened into it was folded away
        // for want of room and back again until AppKit ended the app.
        //
        // The key window, or the main one — or, in an app that is not active, the first one on
        // screen.
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow
                ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }),
              !window.styleMask.contains(.fullScreen),
              let screen = window.screen?.visibleFrame else { return }
        let needed = Theme.Size.windowMinimum
        guard window.frame.width < needed else { return }
        var frame = window.frame
        frame.size.width = min(screen.width, needed)
        // Past the screen's right edge, the window moves left by as much as it has to.
        frame.origin.x -= max(0, frame.maxX - screen.maxX)
        window.setFrame(frame, display: true)
    }

    /// With the column already open — left open, and the app launched again — it is the content
    /// that presents it, so the room is made here first.
    func attach(_ content: AnyView, owner: UUID) {
        if isOpen { makeRoom() }
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
                .inspectorColumnWidth(Theme.Size.sideColumn)
        }
        .environment(\.infoColumn, column)
    }
}
#endif
