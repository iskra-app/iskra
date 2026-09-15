import Foundation
import Intents
import UserNotifications

/// Making a message from a person look like a message from a person.
///
/// This is what iMessage and Telegram do, and it is not a style: a notification that carries an
/// `INSendMessageIntent` is drawn by iOS as a *communication* — the sender's avatar in a circle,
/// their name where the app's name would be, their own line in Notification Summary, and an
/// exemption from a Focus that is allowing people through. None of that is available to a
/// notification the app draws itself, however carefully.
///
/// The whole trick is one call, `content.updating(from:)`, and everything here exists to build the
/// argument it takes.
///
/// ## What it needs
///
/// `com.apple.developer.usernotifications.communication`, on both bundles — and it is the one
/// entitlement in this project Xcode cannot add to a Team Provisioning Profile by itself: the
/// capability has to be switched on for both App IDs at developer.apple.com first, and then the
/// profile re-issued (`xcodebuild -allowProvisioningUpdates`), because until it is re-issued the
/// build fails with the *same* message as when the capability was never enabled.
///
/// Without the entitlement `updating(from:)` throws, the throw is caught, and the plain
/// notification is returned untouched. That fallback stays whether or not the entitlement is
/// there: an app that shows nothing because it could not decorate a notification would be worse
/// than one that never tried.
public enum CommunicationNotification {
    /// Rewrites a notification as a message from a person, or returns it exactly as it was.
    ///
    /// Never throws and never loses the notification. The picture is the part that can go missing,
    /// and it is the part that matters least.
    public static func apply(to content: UNNotificationContent,
                             for notification: PushNotification) -> UNNotificationContent {
        guard let intent = intent(for: notification) else { return content }

        // Donating is what teaches the system that this conversation exists — it is how the room
        // turns up in the share sheet's top row and in Siri's suggestions, and it is also what
        // gives the notification somewhere to belong. Best-effort on purpose: a failed donation
        // is a missing suggestion, not a missing message.
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .incoming
        interaction.donate(completion: nil)

        do {
            return try content.updating(from: intent)
        } catch {
            // The expected path until the capability is enabled, and the reason this is `.info`
            // rather than `.error`: it is a notification drawn the plain way, which is what this
            // app did for its whole life until now.
            Log.push.info("the notification stayed in its plain form: \(Log.describe(error), privacy: .public)")
            return content
        }
    }

    /// The intent that describes "this person said this, in this conversation".
    ///
    /// Nil when there is no person to describe — an invitation from someone with no name and no
    /// ID, or a notification we stripped down because the app is locked. A communication
    /// notification with nobody in it would be worse than a plain one: it would draw an empty
    /// circle where a face goes.
    static func intent(for notification: PushNotification) -> INSendMessageIntent? {
        guard let personID = notification.personID, let personName = notification.personName else {
            return nil
        }

        let person = INPerson(
            personHandle: INPersonHandle(value: personID, type: .unknown),
            nameComponents: nil,
            displayName: personName,
            image: notification.avatar.flatMap(INImage.init(imageData:)),
            contactIdentifier: nil,
            // The Matrix ID, again, and this is the field iOS groups by. A display name changes
            // when somebody renames themselves; this does not, so yesterday's messages and
            // today's stay one conversation with one person.
            customIdentifier: personID
        )

        // A room with people in it, rather than a chat with one person. `sender` is the mapper's
        // answer to "is there a name to put on the second line", and it is nil in a direct chat
        // precisely because the room *is* the person — which is the same question asked here.
        let isGroup = notification.sender != nil

        let intent = INSendMessageIntent(
            recipients: nil,
            outgoingMessageType: .outgoingMessageText,
            // The message itself is deliberately left out. iOS does not need it — the body is
            // already on the notification — and an intent is donated to the system, which is a
            // longer-lived place than a banner that disappears.
            content: nil,
            speakableGroupName: isGroup ? INSpeakableString(spokenPhrase: notification.title) : nil,
            // The room, so that every message from one conversation lands in one thread. The same
            // identifier `threadIdentifier` uses, for the same reason.
            conversationIdentifier: notification.roomID,
            serviceName: nil,
            sender: person,
            attachments: nil
        )

        // In a group the circle shows the *room*, not whoever spoke — but a room avatar is not
        // fetched here, so what goes in is the sender's picture again. Better a face than the grey
        // placeholder iOS draws for a group with no image at all.
        //
        // iOS-only, and not by choice: `setImage(_:forParameterNamed:)` is unavailable on macOS,
        // where there are no communication notifications to put a group picture on. The rest of
        // this file builds on both platforms because it is `IskraCore`, and `IskraCore` compiles
        // for the Mac whether or not every line of it has anything to do there.
        #if os(iOS)
        if isGroup, let image = notification.avatar.flatMap(INImage.init(imageData:)) {
            intent.setImage(image, forParameterNamed: \.speakableGroupName)
        }
        #endif

        return intent
    }
}
