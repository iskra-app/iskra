import SwiftUI
import IskraCore

public extension EnvironmentValues {
    /// The account's block list, handed down so a message's menu can block its sender without being
    /// wired to the session. Nil until a session is up.
    @Entry var blockStore: BlockStore?

    /// The app lock, so the settings screen can switch it on and choose its timeout. Nil in previews
    /// and anywhere the root has not put one up.
    @Entry var appLock: AppLock?

    /// The signed-in user's Matrix ID, handed down so a message bubble can tell when a mention is of
    /// *you* without being given the whole session. Empty until a session is up.
    @Entry var currentUserID: String = ""

    /// And the name that user goes by, so a mention written as "@Name" — not as a raw ID — still
    /// lights up when it is aimed at you.
    @Entry var currentUserName: String = ""

    /// And that user's picture, so a group's cluster of faces can include the one person every
    /// group in the list has in common: the reader.
    @Entry var currentUserAvatarURL: String?
}
