import Foundation
import MatrixRustSDK

/// One thing a room can allow or withhold, by role.
///
/// The ones `Room.applyPowerLevelChanges` can actually move. Matrix keeps a threshold for every
/// event type there is, and a screen listing all of them would be the data model again; these are
/// the eight a person running a group has an opinion about.
public enum RoomRule: String, CaseIterable, Sendable, Identifiable {
    case sendMessages
    case invite
    case remove
    case ban
    case deleteOthers
    case rename
    case changeTopic
    case changePicture

    public var id: String { rawValue }

    /// The threshold, read off the room's values.
    func level(in values: RoomPowerLevelsValues) -> Int64 {
        switch self {
        case .sendMessages: values.eventsDefault
        case .invite: values.invite
        case .remove: values.kick
        case .ban: values.ban
        case .deleteOthers: values.redact
        case .rename: values.roomName
        case .changeTopic: values.roomTopic
        case .changePicture: values.roomAvatar
        }
    }

    /// A change that moves this threshold and nothing else.
    func change(to level: Int64) -> RoomPowerLevelChanges {
        switch self {
        case .sendMessages: RoomPowerLevelChanges(eventsDefault: level)
        case .invite: RoomPowerLevelChanges(invite: level)
        case .remove: RoomPowerLevelChanges(kick: level)
        case .ban: RoomPowerLevelChanges(ban: level)
        case .deleteOthers: RoomPowerLevelChanges(redact: level)
        case .rename: RoomPowerLevelChanges(roomName: level)
        case .changeTopic: RoomPowerLevelChanges(roomTopic: level)
        case .changePicture: RoomPowerLevelChanges(roomAvatar: level)
        }
    }
}

/// Who may do what in a room: each `RoomRule`, and the lowest role that may.
///
/// A threshold is a number and a role is a rung, so a room that set "kick" to 75 — between the
/// moderators' 50 and the administrators' 100 — is read as *administrators*: the lowest rung that
/// clears it. Saying "moderators" there would be the screen claiming a moderator can do something
/// the server will refuse them.
public struct RoomRules: Sendable, Equatable {
    public let levels: [RoomRule: Int]

    public init(levels: [RoomRule: Int]) {
        self.levels = levels
    }

    init(_ values: RoomPowerLevelsValues) {
        levels = Dictionary(uniqueKeysWithValues: RoomRule.allCases.map { ($0, Int($0.level(in: values))) })
    }

    /// The lowest role that may do this.
    public func role(for rule: RoomRule) -> RoomRole {
        Self.role(clearing: levels[rule] ?? 0)
    }

    static func role(clearing level: Int) -> RoomRole {
        let ascending = RoomRole.allCases.sorted { $0.rank > $1.rank }
        return ascending.first { RoomDetailsStore.authority(of: $0) >= .level(level) } ?? .administrator
    }
}
