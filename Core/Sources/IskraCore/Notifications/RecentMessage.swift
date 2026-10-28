import Foundation
import MatrixRustSDK

/// Finds a real message to try a push on.
///
/// A diagnostic, not a feature, and it lives in `IskraCore` for exactly the reason
/// `DeviceListProbe` does: answering it means holding a `Client` and walking a timeline, and
/// the app shell above is allowed neither.
///
/// It exists because of a flaw in the obvious shape of `--probe-notification`. That probe
/// wanted a room ID and an event ID typed in by hand — and *nobody has an event ID to hand*.
/// They are not in the interface, they are not in the logs at a level that is safe to turn
/// on, and a diagnostic you cannot run without one is a diagnostic nobody runs. So when the
/// probe is given no arguments, this finds the most recent real message in the first room
/// that has one, and the probe decrypts that.
@MainActor
enum RecentMessage {
    static func mostRecent(client: Client) async -> (roomID: String, eventID: String)? {
        let ownUserID = (try? client.userId()) ?? ""

        for room in client.rooms() {
            let store = TimelineStore(room: room, ownUserID: ownUserID)

            // A live timeline arrives empty and history is *fetched* — see `CLAUDE.md`. This
            // is `start()` rather than a read of `rows` for that reason: without it the room
            // would look like it had never been spoken in.
            guard (try? await store.start()) != nil else {
                store.stop()
                continue
            }

            let eventID = store.rows.reversed().compactMap { row -> String? in
                guard case let .message(message) = row else { return nil }
                // A transaction ID is not an event ID. A message still in the send queue has no
                // event on the server yet, so no push could ever name it, and asking the SDK to
                // find one would fail in a way that looked like a broken decrypt.
                return message.id.hasPrefix("$") ? message.id : nil
            }.first

            store.stop()

            if let eventID {
                return (room.id(), eventID)
            }
        }

        return nil
    }
}
