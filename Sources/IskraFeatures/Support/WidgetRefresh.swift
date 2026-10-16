import Foundation
import WidgetKit
import IskraCore

/// Tells the favourites widget to draw itself again — and only when there is something new to draw.
///
/// The directory is rewritten on every change to the room list, which on a busy account is several
/// times a second. WidgetKit gives an app a small daily budget of reloads and quietly stops honouring
/// them once it is spent, so reloading on every write would leave the widget frozen by lunchtime. What
/// the widget actually shows — faces, names, dots, the lock — is reduced to one string
/// (`WidgetChats.fingerprint`), and only a different string reloads it.
@MainActor
enum WidgetRefresh {
    private static var last: String?

    static func directoryChanged(activeAccount: String?) {
        let defaults = ChatDirectory.sharedDefaults
        let fingerprint = WidgetChats.fingerprint(ChatDirectory.directory(from: defaults),
                                                  chosen: Array(WidgetChats.chosen(in: defaults)),
                                                  account: activeAccount,
                                                  locked: AppLock.isEnabled(defaults: defaults))
        guard fingerprint != last else { return }
        last = fingerprint
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetChats.kind)
    }
}
