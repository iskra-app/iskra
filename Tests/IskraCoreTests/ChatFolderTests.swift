import Foundation
import Testing
@testable import IskraCore

/// Which chats a folder holds — see `ChatFolder`.
@Suite("Chat folders")
struct ChatFolderTests {
    private let dm = RoomSummary(id: "!dm", name: "Аня", kind: .direct)
    private let group = RoomSummary(id: "!group", name: "Семья", kind: .group, unreadMessageCount: 2)
    private let muted = RoomSummary(id: "!muted", name: "Шум", kind: .group, isMuted: true)
    private let archived = RoomSummary(id: "!old", name: "Старое", kind: .direct, isLowPriority: true)
    private let space = RoomSummary(id: "!space", name: "Работа", kind: .space)

    @Test("kinds pick the chats, in the list's order")
    func kinds() {
        let folder = ChatFolder(name: "Группы", kinds: [.groups])
        #expect(folder.rooms(from: [dm, group, muted, space]).map(\.id) == ["!group", "!muted"])
    }

    @Test("conditions narrow them")
    func conditions() {
        let all: [RoomSummary] = [dm, group, muted]
        #expect(ChatFolder(name: "x", kinds: [.direct, .groups], onlyUnread: true).rooms(from: all).map(\.id) == ["!group"])
        #expect(ChatFolder(name: "x", kinds: [.groups], excludesMuted: true).rooms(from: all).map(\.id) == ["!group"])
    }

    @Test("the archive stays out unless asked for")
    func archive() {
        #expect(ChatFolder(name: "x", kinds: [.direct]).rooms(from: [dm], archived: [archived]).map(\.id) == ["!dm"])
        #expect(ChatFolder(name: "x", kinds: [.direct], includesArchived: true)
                    .rooms(from: [dm], archived: [archived]).map(\.id) == ["!dm", "!old"])
    }

    @Test("by hand beats the kinds; left out beats everything")
    func byHand() {
        let folder = ChatFolder(name: "x", kinds: [.groups], included: ["!dm"], excluded: ["!group"])
        #expect(folder.rooms(from: [dm, group, muted]).map(\.id) == ["!dm", "!muted"])
    }

    @Test("a folder with no rule is not saved")
    func meaningful() {
        #expect(!ChatFolder(name: "x").isMeaningful)
        #expect(!ChatFolder(name: " ", kinds: [.direct]).isMeaningful)
        #expect(ChatFolder(name: "x", included: ["!dm"]).isMeaningful)
    }

    @Test("the document goes round, and a folder from a newer version is skipped, not the list")
    func document() {
        let folders = [ChatFolder(name: "Личные", kinds: [.direct]), ChatFolder(name: "Группы", kinds: [.groups], onlyUnread: true)]
        #expect(ChatFolders.decode(ChatFolders.encode(folders)) == folders)

        let mixed = #"{"folders":[{"id":"a","name":"Личные","kinds":["direct"],"onlyUnread":false,"excludesMuted":false,"includesArchived":false,"included":[],"excluded":[]},{"id":"b","name":"?","kinds":["bots"]}]}"#
        #expect(ChatFolders.decode(mixed).map(\.id) == ["a"])
    }
}
