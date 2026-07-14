import Foundation
import MatrixRustSDK

/// The room saying it has changed — its name, its picture, its topic, who is in it, what is pinned.
///
/// One listener type, used by both of the stores that care, and that is the point of it having a
/// file of its own. It used to be private to `TimelineStore`, and the consequence was not a
/// duplicate class but a *missing* one: `RoomDetailsStore` had no way to subscribe, so it read the
/// room once with `roomInfo()` and held the answer. The header above a conversation therefore
/// followed a rename and the room's own info screen did not, and the field showing the name was the
/// field the user would have typed the next name into.
final class RoomInfoUpdates: RoomInfoListener {
    private let onUpdate: @Sendable (RoomInfo) -> Void

    init(onUpdate: @escaping @Sendable (RoomInfo) -> Void) {
        self.onUpdate = onUpdate
    }

    func call(roomInfo: RoomInfo) {
        onUpdate(roomInfo)
    }
}
