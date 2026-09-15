import Testing
import Foundation
import Intents
@testable import IskraCore

/// The intent that turns a notification into a message from a person.
///
/// What it *looks* like on a lock screen cannot be tested anywhere but on a phone, and not even
/// there until the Communication Notifications capability is enabled on the App IDs. What can be
/// pinned here is everything iOS reads: who the person is, which conversation this belongs to, and
/// the identifier that keeps yesterday's messages and today's the same conversation.
struct CommunicationNotificationTests {
    private func notification(sender: String? = nil,
                              personName: String? = "Аня",
                              personID: String? = "@anya:matrix.org",
                              avatar: Data? = nil) -> PushNotification {
        PushNotification(roomID: "!kitchen:matrix.org",
                         eventID: "$1",
                         title: sender == nil ? "Аня" : "Кухня",
                         sender: sender,
                         body: "приду через час",
                         isNoisy: true,
                         personName: personName,
                         personID: personID,
                         avatarURL: "mxc://matrix.org/abc",
                         avatar: avatar)
    }

    @Test("the message is attributed to the person who sent it")
    func theSenderIsThePerson() throws {
        let intent = try #require(CommunicationNotification.intent(for: notification()))
        let sender = try #require(intent.sender)

        #expect(sender.displayName == "Аня")
        #expect(sender.personHandle?.value == "@anya:matrix.org")
    }

    @Test("the person is identified by their Matrix ID, not their name")
    func theIdentifierOutlivesTheName() throws {
        let intent = try #require(CommunicationNotification.intent(for: notification()))

        // What iOS groups by. A display name changes the day somebody renames themselves, and a
        // conversation that splits in two on that day is the bug this pins.
        #expect(try #require(intent.sender).customIdentifier == "@anya:matrix.org")
    }

    @Test("every message from one room is one conversation")
    func theRoomIsTheConversation() throws {
        let intent = try #require(CommunicationNotification.intent(for: notification()))

        #expect(intent.conversationIdentifier == "!kitchen:matrix.org")
    }

    @Test("a direct chat is not a group")
    func aDirectChatHasNoGroupName() throws {
        // `sender` nil is the mapper saying "the room *is* the person" — there is no group here to
        // name, and naming one would put the person's name on the notification twice.
        let intent = try #require(CommunicationNotification.intent(for: notification(sender: nil)))

        #expect(intent.speakableGroupName == nil)
    }

    @Test("a room with people in it is named as one")
    func aGroupCarriesItsName() throws {
        let intent = try #require(CommunicationNotification.intent(for: notification(sender: "Аня")))

        #expect(intent.speakableGroupName?.spokenPhrase == "Кухня")
    }

    @Test("a picture is attached when there is one")
    func theAvatarTravelsWithThePerson() throws {
        let plain = try #require(CommunicationNotification.intent(for: notification()))
        #expect(try #require(plain.sender).image == nil)

        let withFace = try #require(CommunicationNotification.intent(for: notification(avatar: Data([0x1, 0x2]))))
        #expect(try #require(withFace.sender).image != nil)
    }

    @Test("nobody to draw means no communication notification at all")
    func anUnattributableMessageStaysPlain() {
        // An empty circle where a face goes is worse than the plain notification this app drew for
        // its whole life — so there is no intent, and `apply` hands the content back untouched.
        #expect(CommunicationNotification.intent(for: notification(personName: nil, personID: nil)) == nil)
        #expect(CommunicationNotification.intent(for: notification(personID: nil)) == nil)
    }
}
