import Testing
import Foundation
import MatrixRustSDK
@testable import IskraCore

/// What a room is, and whose face belongs beside it.
///
/// Both answers are pure functions of one `RoomInfo`, which is why they are here rather than on a
/// homeserver: the rules they encode — that a group of two is still a group, that a personal chat
/// wears the other person's picture and a group never does — are exactly the kind that is easy to
/// get right once and quietly break later.
@Suite("Room kind")
struct RoomKindTests {

    // MARK: - What the room is

    @Test("A group with two people in it is still a group")
    func groupOfTwoIsNotPersonal() {
        let room = Self.info(isDirect: false, isDm: false, joined: 2)

        #expect(room.kind == .group)
        #expect(!room.isOneToOne)
    }

    @Test("A personal chat with a third person invited is still a personal chat")
    func personalChatSurvivesAThirdPerson() {
        let room = Self.info(isDirect: true, isDm: false, joined: 3)

        // What it *is* does not change. How it is laid out does — three people need names above
        // their messages, whatever the room was started as.
        #expect(room.kind == .direct)
        #expect(!room.isOneToOne)
    }

    @Test("A personal chat of two is both")
    func personalChatOfTwo() {
        let room = Self.info(isDirect: true, isDm: true, joined: 2)

        #expect(room.kind == .direct)
        #expect(room.isOneToOne)
    }

    @Test("A space is a space before it is anything else")
    func spaceIsSettledFirst() {
        let room = Self.info(isDirect: true, isDm: true, joined: 2, isSpace: true)

        #expect(room.kind == .space)
    }

    @Test("Before the first sync there is nobody to count, so the SDK's own answer stands")
    func unsyncedRoomTrustsTheSDK() {
        let room = Self.info(isDirect: true, isDm: true, joined: 0, invited: 0)

        #expect(room.isOneToOne)
    }

    @Test("An invitation not yet accepted is still a chat between two")
    func invitedMemberCounts() {
        let room = Self.info(isDirect: true, isDm: true, joined: 1, invited: 1)

        #expect(room.isOneToOne)
    }

    // MARK: - Whose face

    @Test("A personal chat with no picture of its own wears the other person's")
    func personalChatBorrowsTheCounterpartsPicture() {
        let room = Self.info(isDirect: true, isDm: true, joined: 2, avatarURL: nil,
                             heroes: [Self.hero(id: "@anya:example.org", avatar: "mxc://anya")])

        #expect(room.pictureURL(besides: Self.ownID) == "mxc://anya")
    }

    @Test("A group with no picture of its own wears none")
    func groupDoesNotBorrowAFace() {
        // The hero is one member the server named to describe the room. Their photograph is not
        // the room's, and hanging it there would label a group with a stranger's face.
        let room = Self.info(isDirect: false, isDm: false, joined: 5, avatarURL: nil,
                             heroes: [Self.hero(id: "@anya:example.org", avatar: "mxc://anya")])

        #expect(room.pictureURL(besides: Self.ownID) == nil)
    }

    @Test("A picture the room set for itself wins")
    func ownPictureWins() {
        let room = Self.info(isDirect: true, isDm: true, joined: 2, avatarURL: "mxc://room",
                             heroes: [Self.hero(id: "@anya:example.org", avatar: "mxc://anya")])

        #expect(room.pictureURL(besides: Self.ownID) == "mxc://room")
    }

    @Test("Our own face is never the face of our own chat")
    func ownFaceIsNotTheCounterparts() {
        // A note-to-self room has only us in it. Initials are the right answer there; our own
        // photograph pretending to be the person we are talking to is not.
        let room = Self.info(isDirect: true, isDm: true, joined: 1, avatarURL: nil,
                             heroes: [Self.hero(id: Self.ownID, avatar: "mxc://me")])

        #expect(room.pictureURL(besides: Self.ownID) == nil)
        #expect(room.counterpart(besides: Self.ownID) == nil)
    }

    // MARK: - What it is called

    @Test("A nameless personal chat is called by the other person")
    func namelessChatTakesTheCounterpartsName() {
        let room = Self.info(isDirect: true, isDm: true, joined: 2, displayName: nil,
                             heroes: [Self.hero(id: "@anya:example.org", name: "Аня")])

        #expect(room.title(besides: Self.ownID) == "Аня")
    }

    @Test("The name and the picture fall back together")
    func nameAndPictureAgree() {
        // The bug this pins: the name knew about the heroes and the picture did not, so a chat
        // showed somebody's name beside a circle of initials with their photograph one field away.
        let room = Self.info(isDirect: true, isDm: true, joined: 2, displayName: nil, avatarURL: nil,
                             heroes: [Self.hero(id: "@anya:example.org", name: "Аня", avatar: "mxc://anya")])

        #expect(room.title(besides: Self.ownID) == "Аня")
        #expect(room.pictureURL(besides: Self.ownID) == "mxc://anya")
    }

    // MARK: - Building one

    private static let ownID = "@me:example.org"

    private static func hero(id: String, name: String? = nil, avatar: String? = nil) -> RoomHero {
        RoomHero(userId: id, displayName: name, avatarUrl: avatar, status: nil, call: nil)
    }

    /// A `RoomInfo` with everything that does not matter here left at its emptiest. The SDK's
    /// memberwise initialiser is forty fields wide, and spelling it out once is what keeps each
    /// test above down to the three or four that are actually the subject.
    private static func info(isDirect: Bool,
                             isDm: Bool,
                             joined: UInt64,
                             invited: UInt64 = 0,
                             isSpace: Bool = false,
                             displayName: String? = "Чат",
                             avatarURL: String? = nil,
                             heroes: [RoomHero] = []) -> RoomInfo {
        RoomInfo(id: "!room:example.org",
                 encryptionState: .encrypted,
                 creators: nil,
                 displayName: displayName,
                 rawName: displayName,
                 topic: nil,
                 avatarUrl: avatarURL,
                 isDirect: isDirect,
                 isDm: isDm,
                 isPublic: false,
                 isSpace: isSpace,
                 successorRoom: nil,
                 isFavourite: false,
                 isLowPriority: false,
                 canonicalAlias: nil,
                 alternativeAliases: [],
                 membership: .joined,
                 inviter: nil,
                 heroes: heroes,
                 activeMembersCount: joined,
                 invitedMembersCount: invited,
                 joinedMembersCount: joined,
                 activeServiceMembersCount: 0,
                 serviceMembers: [],
                 highlightCount: 0,
                 notificationCount: 0,
                 cachedUserDefinedNotificationMode: nil,
                 hasRoomCall: false,
                 activeRoomCallParticipants: [],
                 activeRoomCallConsensusIntent: .none,
                 isMarkedUnread: false,
                 numUnreadMessages: 0,
                 numUnreadNotifications: 0,
                 numUnreadMentions: 0,
                 fullyReadEventId: nil,
                 pinnedEventIds: [],
                 joinRule: nil,
                 historyVisibility: .shared,
                 powerLevels: nil,
                 roomVersion: nil,
                 privilegedCreatorsRole: false)
    }
}
