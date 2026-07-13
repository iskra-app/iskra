import Foundation
import Observation
import MatrixRustSDK

/// Where a member stands in a room. Three rungs, not a number.
///
/// Matrix models this as a power level — an integer, 0 to 100, that also decides who may
/// kick whom. Showing "power level 50" beside someone's face would be leaking the data
/// model into the user's face, so the SDK's own reading of that integer is used instead
/// and everyone who is merely present gets no badge at all.
public enum RoomRole: Sendable, Equatable {
    case administrator
    case moderator
    case member

    /// Administrators first, then moderators, then everyone else.
    var rank: Int {
        switch self {
        case .administrator: 0
        case .moderator: 1
        case .member: 2
        }
    }
}

/// One person in a room.
public struct RoomMemberSummary: Sendable, Identifiable, Equatable {
    /// The Matrix ID — "@boris:matrix.org". Also the identity, so it is the `id`.
    public let id: String
    /// What they call themselves, falling back to their Matrix ID when they have not
    /// said. Never empty.
    public let name: String
    public let avatarURL: String?
    public let role: RoomRole

    /// True when someone else in this room calls themselves the same thing.
    ///
    /// Matrix display names are not unique and are not verified, so "Boris" in a room can
    /// be two different people — which is a small, cheap impersonation. The SDK spots it;
    /// the members list then shows the Matrix ID beside the name, because the ID is the
    /// part nobody can copy.
    public let isNameAmbiguous: Bool
}

/// Everything the room-info screen shows: what the room is, and who is in it.
///
/// Separate from `TimelineStore` on purpose. A conversation needs a name and a lock in
/// its header and nothing else, and it needs them on the first frame; the member list is
/// a screenful of requests that most people never open. Loading it lazily, from its own
/// store, is what keeps opening a chat cheap.
@MainActor
@Observable
public final class RoomDetailsStore {
    public private(set) var name = ""
    public private(set) var topic: String?
    public private(set) var avatarURL: String?
    public private(set) var privacy: PrivacyStatus = .unknown
    public private(set) var isDirectChat = false

    /// The other person's Matrix ID, in a chat that has exactly one other person.
    /// Nil in a room, and nil in a chat with only yourself in it.
    public private(set) var counterpartID: String?

    /// The number of people who have actually joined — not those merely invited, who are
    /// not here yet and may never be.
    public private(set) var memberCount = 0
    public private(set) var members: [RoomMemberSummary] = []
    public private(set) var isLoadingMembers = true

    private let room: Room
    private let ownUserID: String

    init(room: Room, ownUserID: String) {
        self.room = room
        self.ownUserID = ownUserID
    }

    /// Loads the room, then the people in it.
    ///
    /// In two passes, because the two have very different costs. The cached member list
    /// is already on disk and comes back at once; the fresh one is a request to the
    /// server that a large room can keep waiting. Showing the cached list first means the
    /// screen is populated immediately and then quietly corrects itself, rather than
    /// holding a spinner in front of an answer we already had.
    public func load() async {
        if let info = try? await room.roomInfo() {
            name = info.displayName ?? info.heroes.first?.displayName ?? String(core: CoreStrings.Room.untitled)
            topic = info.topic
            avatarURL = info.avatarUrl
            privacy = PrivacyStatus(info.encryptionState)
            isDirectChat = info.isDm
            memberCount = Int(info.joinedMembersCount)
            counterpartID = info.isDm ? info.heroes.first(where: { $0.userId != ownUserID })?.userId : nil
        }

        if let cached = try? await room.membersNoSync() {
            apply(Self.summaries(from: cached))
        }

        if let fresh = try? await room.members() {
            apply(Self.summaries(from: fresh))
        }

        isLoadingMembers = false
    }

    private func apply(_ loaded: [RoomMemberSummary]) {
        guard !loaded.isEmpty else { return }

        members = loaded
        memberCount = loaded.count
        isLoadingMembers = false

        // The heroes are the server's summary of a room and can be missing; the member
        // list never is. So once it has arrived, it settles who the other person is.
        if isDirectChat, counterpartID == nil {
            counterpartID = loaded.first { $0.id != ownUserID }?.id
        }
    }

    /// Drains the SDK's member iterator into value types the UI can diff.
    ///
    /// Only people who have joined. An invitation nobody has accepted is not a member —
    /// counting one would put a face in the list for someone who has never been in the
    /// room, and a number in the header that no one else's client agrees with.
    private static func summaries(from iterator: RoomMembersIterator) -> [RoomMemberSummary] {
        var summaries: [RoomMemberSummary] = []
        summaries.reserveCapacity(Int(iterator.len()))

        while let chunk = iterator.nextChunk(chunkSize: 100) {
            for member in chunk where member.membership == .join && !member.isServiceMember {
                summaries.append(RoomMemberSummary(id: member.userId,
                                                   name: member.displayName ?? member.userId,
                                                   avatarURL: member.avatarUrl,
                                                   role: RoomRole(member.suggestedRoleForPowerLevel),
                                                   isNameAmbiguous: member.isNameAmbiguous))
            }
        }

        // Whoever runs the room first, then everyone else by name — and by the *locale's*
        // idea of order, so a Russian room does not sort its members as if they were
        // English.
        return summaries.sorted { first, second in
            if first.role.rank != second.role.rank { return first.role.rank < second.role.rank }
            return first.name.localizedStandardCompare(second.name) == .orderedAscending
        }
    }
}

private extension RoomRole {
    /// A room's creator holds an infinite power level and cannot be demoted. That is a
    /// distinction the room's *rules* care about and a reader does not: both run the
    /// place, so both read as an administrator.
    init(_ role: RoomMemberRole) {
        switch role {
        case .creator, .administrator: self = .administrator
        case .moderator: self = .moderator
        default: self = .member
        }
    }
}
