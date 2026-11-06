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
        didSet {
            UserDefaults.standard.set(isOpen, forKey: Self.openKey)
            settleMinimum()
        }
    }

    /// What the column shows: the open chat's info, built by that chat.
    private(set) var content: AnyView?
    /// Whose `content` is — also its identity in the column, so that the next chat's info is a new
    /// view rather than the last one's state under a new room (see `infoColumn(_:)`).
    private(set) var owner: UUID?

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
    ///
    /// The narrow minimum goes on with the column and comes off only once it has gone. Taken off at
    /// the same moment, the chat asked for its full width while the column was still being counted
    /// — twice — and SwiftUI stretched the window to fit both — to two screens wide — and left it there
    /// (`Iskra --probe-resize open narrow toggle`).
    var conversationMinimumWidth: CGFloat {
        paysForColumn
            ? Theme.Size.conversationMinimum.width - Theme.Size.sideColumn
            : Theme.Size.windowMinimum - Theme.Size.sideColumn
    }

    /// Whether the chat's minimum is the narrow one — see `conversationMinimumWidth`.
    private var paysForColumn = false

    /// How long the column is given to go before the chat takes its width back.
    private static let columnGone: Duration = .milliseconds(600)

    private func settleMinimum() {
        if isPresented {
            paysForColumn = true
            return
        }
        guard paysForColumn else { return }
        Task { @MainActor in
            try? await Task.sleep(for: Self.columnGone)
            if !isPresented { paysForColumn = false }
        }
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
        settleMinimum()
    }

    /// Takes the content away if it is still this owner's — a chat that goes after the next one
    /// arrived must not empty the column the next one just filled. The column stays as open or as
    /// closed as the user left it.
    ///
    /// Emptied a turn later, not at once. Going from one chat to the next, the old one may leave
    /// before the new one arrives, and for that moment the column had nothing in it: the inspector
    /// shut, said so through its binding, and the user's "open" was forgotten — the column closed
    /// on every change of chat. A turn later the next chat has already filled it.
    func detach(owner: UUID) {
        guard self.owner == owner else { return }
        Task { @MainActor in
            guard self.owner == owner else { return }
            content = nil
            self.owner = nil
            settleMinimum()
        }
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
        // Shut from the column's side only while it has something in it: a column that went shut
        // because it was emptied is not the user closing it.
        inspector(isPresented: Binding(get: { column.isPresented },
                                       set: { if !$0, column.content != nil { column.isOpen = false } })) {
            column.content
                // One chat's info and the next's are the same type in the same place, and SwiftUI
                // kept the first one's state — its stack, its store — under the second: the column
                // stayed open on the previous chat.
                .id(column.owner)
                // The seam between the conversation and this column: the same line as on the
                // list's side of it (`IskraRootView`), so the window has one kind of rule.
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(.separator)
                        .frame(width: Theme.Border.hairline)
                        .ignoresSafeArea()
                }
                .inspectorColumnWidth(Theme.Size.sideColumn)
        }
        .environment(\.infoColumn, column)
    }
}
#endif
