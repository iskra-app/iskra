import Foundation

public extension UserSession {
    /// This account's chats as the share sheet, Siri and the widget know them — joined
    /// conversations only, not spaces and not invitations — and the pictures for them asked for on
    /// the way past (`ChatFaces`).
    ///
    /// An entry names its picture only once the file is there. Until then it has none and the
    /// creature is drawn; `chatFaces.revision` going up is the cue to write the list again.
    ///
    /// With "always a creature" switched on nothing is fetched at all — downloading a photograph in
    /// order to hide it is the same mistake `Avatar.load` and the notification extension avoid.
    func chatDirectoryEntries(for rooms: [RoomSummary]) -> [ChatDirectoryEntry] {
        let chats = rooms.filter { !$0.isInvitation && !$0.isSpace }
        let realFaces = !BetaFeatures.drawsGeneratedFace(hasPicture: true)

        if realFaces {
            let candidates = chats.map {
                DirectoryFaces.Candidate(entityID: "\(sessionID)|\($0.id)",
                                         avatarURL: $0.avatarURL,
                                         isPinned: $0.isFavourite)
            }
            chatFaces.want(DirectoryFaces.wanted(candidates, chosen: WidgetChats.chosen()))
        }

        return chats.map { room in
            ChatDirectoryEntry(id: room.id, name: room.name,
                               accountID: sessionID, accountName: displayName,
                               avatarSeed: room.avatarSeed,
                               faceFile: realFaces ? chatFaces.file(for: room.avatarURL) : nil,
                               isPinned: room.isFavourite,
                               unreadCount: room.hasUnreadCount ? room.unreadNotifyingMessages : 0)
        }
    }
}
