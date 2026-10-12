import Foundation

/// Which grey lines a conversation leaves out — Settings → Chats.
///
/// Two switches and not one, because they are two different kinds of noise. In a big public room
/// "joined" and "left" are most of what happens and nobody wants to read them; somebody renaming
/// themselves is rarer and is how you learn that "Kot" is now "Аня". So each can go on its own.
///
/// Room events the person *did to the room* — a new name for the chat, its picture, encryption —
/// stay whatever these say: they are about the conversation itself, and there are few of them.
public struct ServiceEventSettings: Sendable, Equatable {
    public var hidesNameChanges: Bool
    public var hidesMembershipChanges: Bool

    public init(hidesNameChanges: Bool = false, hidesMembershipChanges: Bool = false) {
        self.hidesNameChanges = hidesNameChanges
        self.hidesMembershipChanges = hidesMembershipChanges
    }

    public static let hidesNameChangesKey = "chats.hidesNameChanges"
    public static let hidesMembershipChangesKey = "chats.hidesMembershipChanges"

    /// Every key, for `AppSettings.forget`.
    public static let keys = [hidesNameChangesKey, hidesMembershipChangesKey]

    /// What the settings screen says right now. Both off unless somebody turned them on.
    public static func current(_ defaults: UserDefaults = .standard) -> ServiceEventSettings {
        ServiceEventSettings(hidesNameChanges: defaults.bool(forKey: hidesNameChangesKey),
                             hidesMembershipChanges: defaults.bool(forKey: hidesMembershipChangesKey))
    }

    /// Whether this line is left out of the conversation.
    public func hides(_ kind: RoomEventKind) -> Bool {
        switch kind {
        case .renamedThemselves:
            hidesNameChanges
        case .joined, .left, .invited, .removed, .banned:
            hidesMembershipChanges
        case .roomRenamed, .roomTopicChanged, .roomPictureChanged, .roomCreated, .encryptionEnabled:
            false
        }
    }
}
