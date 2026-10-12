import Foundation
import IskraCore

/// Something that stopped the user before the room was ever asked.
///
/// Distinct from `TimelineActionFailure`, and the distinction is not pedantry: that one is the room
/// refusing something — a message that would not send, a reaction that did not land — and this one
/// is the *device*. The microphone is not ours to use; the file the picker handed over cannot be
/// read. Matrix never heard about either, and the store that talks to Matrix should not be carrying
/// them.
///
/// It used to. `RoomView` wrote its own sentences straight into `TimelineStore.sendFailure`, which
/// is a view reaching into the model layer to park its alert state there — the same thing
/// `UserSession` was doing with photo-library errors before the account actions learned to throw.
/// The store is the app's, and lives as long as the room is open; a permission the user declined
/// belongs to the screen that asked.
enum RoomProblem: String, CaseIterable, ActionFailure {
    /// The microphone was refused, so a hold that would have recorded produced nothing. Saying so
    /// matters: silence looks exactly like the app being broken, when in fact it is being obedient.
    case microphone

    /// The picker handed back something that could not be read — a file the system would not open,
    /// a photo that would not decode. Nothing was uploaded, and nothing was sent.
    case unreadableAttachment

    /// "Send anyway" was pressed and the SDK refused — the message is still stuck, and saying so
    /// is better than a badge that quietly stays red.
    case sendAnywayFailed

    /// "Got it" on a changed identity did not take, so the warning is still up — and will be
    /// back on the next launch if the screen pretended otherwise.
    case identityNotAcknowledged

    var id: String { rawValue }

    var explanation: LocalizedStringResource {
        switch self {
        case .microphone: Strings.Voice.needsMicrophone
        case .unreadableAttachment: Strings.Room.attachmentUnreadable
        case .sendAnywayFailed: Strings.Message.Delivery.sendAnywayFailed
        case .identityNotAcknowledged: Strings.Room.Identity.failed
        }
    }
}
