import Foundation
import IskraCore
import IskraDesign

/// The face on a notification, when the sender has not got one.
///
/// It lives here, in a file compiled into *both* the app and the notification extension, because
/// two processes have to answer this identically: the extension, which puts the picture on the
/// banner, and `--probe-notification`, which exists to say what the banner will look like. A probe
/// that reasons about this separately is a probe that can be wrong in exactly the case it was
/// written to diagnose.
///
/// This is the seam the whole thing turns on. `Avatar` draws a blobatar in a view, in the app's
/// process; a push arrives in the other one, and `INImage` — which is what fills the circle on a
/// notification — takes bytes and nothing else. So the creature is drawn again here, from the same
/// seed (the Matrix ID, never the display name) through the same generator, and comes out the same
/// creature.
enum PushFace {
    /// The notification with a picture on it: the sender's own, or the creature they come out as.
    ///
    /// Unchanged in two cases, both correct. There is no ID to seed a face from — a sender we know
    /// nothing about, which includes every notification stripped down because the app is locked,
    /// and drawing a face on one of those would give back exactly what the lock took away. Or the
    /// user has not asked for generated faces, and iOS's own grey placeholder is the answer they
    /// chose.
    static func applied(to notification: PushNotification) -> PushNotification {
        guard let seed = notification.personID,
              BetaFeatures.drawsGeneratedFace(hasPicture: notification.avatar != nil)
        else { return notification }

        return notification.withAvatar(BlobatarImage.pngData(for: seed))
    }
}
