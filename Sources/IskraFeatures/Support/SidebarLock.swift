#if os(macOS)
import AppKit
import IskraDesign
import SwiftUI

/// Holds the list of chats at its one width: it cannot be dragged, folded or collapsed.
///
/// `navigationSplitViewColumnWidth` does not do that by itself. The column could still be dragged to
/// nothing, which left a window with no list and, with its toggle taken away (`RoomListView`), no
/// way to get it back. And a column that can collapse is not counted in the window's least width,
/// so the window went down far enough to squeeze the chat beside an open info column. Both are
/// settings of the `NSSplitViewItem` under the column, which SwiftUI does not expose, so it is found
/// through the responder chain.
struct SidebarLock: NSViewRepresentable {
    func makeNSView(context: Context) -> Finder { Finder() }

    func updateNSView(_ view: Finder, context: Context) { view.lock() }

    final class Finder: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            lock()
        }

        func lock() {
            var responder: NSResponder? = self
            while let current = responder {
                if let split = current as? NSSplitViewController, let item = split.splitViewItems.first {
                    let width = Theme.Size.sideColumn
                    if item.isCollapsed { item.isCollapsed = false }
                    item.canCollapse = false
                    item.canCollapseFromWindowResize = false
                    item.minimumThickness = width
                    item.maximumThickness = width
                    return
                }
                responder = current.nextResponder
            }
        }
    }
}
#endif
