import Foundation
import Testing
@testable import IskraCore

/// Real pictures for the share sheet and the widget, and what the widget shows — see
/// `DirectoryFaces`, `ChatFaces` and `WidgetChats`.
@Suite("Directory faces and the widget")
struct DirectoryFacesTests {
    private func freshDefaults(_ name: String) throws -> UserDefaults {
        let suite = "iskra.tests.directoryFaces.\(name)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func freshFolder(_ name: String) throws -> URL {
        let folder = URL.temporaryDirectory.appending(component: "iskra-faces-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func candidate(_ id: String, _ url: String?, pinned: Bool = false) -> DirectoryFaces.Candidate {
        .init(entityID: "acc|\(id)", avatarURL: url, isPinned: pinned)
    }

    // MARK: - Which pictures

    @Test("pinned first, then chosen in a widget, then the top of the list — each picture once")
    func wantedOrder() {
        let chats = [
            candidate("!a", "mxc://s/a"),
            candidate("!b", "mxc://s/b"),
            candidate("!c", "mxc://s/c", pinned: true),
            candidate("!d", nil),
            candidate("!e", "mxc://s/a"),          // the same picture as !a
            candidate("!f", "mxc://s/f"),
        ]
        let wanted = DirectoryFaces.wanted(chats, chosen: ["acc|!f"], recent: 2)
        #expect(wanted == ["mxc://s/c", "mxc://s/f", "mxc://s/a", "mxc://s/b"])
    }

    @Test("a picture's file is named after its address, the same every time and safe as a name")
    func fileNames() {
        let name = DirectoryFaces.fileName(for: "mxc://matrix.org/abc")
        #expect(name == DirectoryFaces.fileName(for: "mxc://matrix.org/abc"))
        #expect(name != DirectoryFaces.fileName(for: "mxc://matrix.org/abd"))
        #expect(SafeFilename.isSafe(name))
        #expect(name.hasSuffix(".jpg"))
    }

    @Test("a name from the shared defaults that would climb out of the folder is refused")
    func unsafeNames() throws {
        let folder = try freshFolder("unsafe")
        #expect(DirectoryFaces.url(of: "../secret", in: folder) == nil)
        #expect(DirectoryFaces.url(of: nil, in: folder) == nil)
        #expect(DirectoryFaces.url(of: "x.jpg", in: folder) == folder.appending(component: "x.jpg"))
    }

    @Test("an entry with no file, or a file not on the disk, draws the creature")
    func missingFile() throws {
        let folder = try freshFolder("missing")
        #expect(DirectoryFaces.url(for: ChatDirectoryEntry(id: "!a", name: "A"), in: folder) == nil)
        #expect(DirectoryFaces.url(for: ChatDirectoryEntry(id: "!a", name: "A", faceFile: "gone.jpg"), in: folder) == nil)
        try Data([1]).write(to: folder.appending(component: "here.jpg"))
        #expect(DirectoryFaces.url(for: ChatDirectoryEntry(id: "!a", name: "A", faceFile: "here.jpg"), in: folder) != nil)
    }

    // MARK: - Tidying

    @Test("the sweep keeps what the directory names and takes the rest")
    func sweep() throws {
        let defaults = try freshDefaults("sweep")
        let folder = try freshFolder("sweep")
        for name in ["kept.jpg", "stale.jpg"] { try Data([1]).write(to: folder.appending(component: name)) }
        ChatDirectory.writeDirectory([ChatDirectoryEntry(id: "!a", name: "A", faceFile: "kept.jpg")], to: defaults)

        DirectoryFaces.sweep(in: folder, defaults: defaults)

        #expect(FileManager.default.fileExists(atPath: folder.appending(component: "kept.jpg").path))
        #expect(!FileManager.default.fileExists(atPath: folder.appending(component: "stale.jpg").path))
    }

    @Test("signing an account out takes its pictures, except one another account still shows")
    func forgetTakesFaces() throws {
        let defaults = try freshDefaults("forget")
        let folder = try freshFolder("forget")
        for name in ["mine.jpg", "shared.jpg", "theirs.jpg"] { try Data([1]).write(to: folder.appending(component: name)) }
        ChatDirectory.writeDirectory([
            ChatDirectoryEntry(id: "!a", name: "A", accountID: "one", faceFile: "mine.jpg"),
            ChatDirectoryEntry(id: "!b", name: "B", accountID: "one", faceFile: "shared.jpg"),
            ChatDirectoryEntry(id: "!c", name: "C", accountID: "two", faceFile: "shared.jpg"),
            ChatDirectoryEntry(id: "!d", name: "D", accountID: "two", faceFile: "theirs.jpg"),
        ], to: defaults)

        ChatDirectory.forget(account: "one", in: defaults, faces: folder)

        let left = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        #expect(left == ["shared.jpg", "theirs.jpg"])
    }

    @Test("an entry written before faces existed still reads")
    func oldEntriesDecode() throws {
        let old = #"[{"id":"!a","name":"Кухня","accountID":"one"}]"#
        let defaults = try freshDefaults("old")
        defaults.set(Data(old.utf8), forKey: "appIntents.chatDirectory")
        let entry = try #require(ChatDirectory.directory(from: defaults).first)
        #expect(entry.faceFile == nil && entry.isPinned == nil && entry.unreadCount == nil)
        #expect(entry.entityID == "one|!a")
    }

    // MARK: - Fetching

    @Test("fetched pictures land as files, and the revision says so")
    @MainActor
    func fetching() async throws {
        let folder = try freshFolder("fetch")
        let faces = ChatFaces(folder: { folder }) { url in
            url.hasSuffix("big") ? Data(count: DirectoryFaces.byteLimit + 1) : Data(url.utf8)
        }
        faces.want(["mxc://s/a", "mxc://s/b", "mxc://s/big"], settle: .zero)
        await faces.settled()

        #expect(faces.revision == 1)
        #expect(faces.file(for: "mxc://s/a") == DirectoryFaces.fileName(for: "mxc://s/a"))
        #expect(faces.file(for: "mxc://s/b") != nil)
        // Too big is refused, and not asked for again.
        #expect(faces.file(for: "mxc://s/big") == nil)
        faces.want(["mxc://s/big"], settle: .zero)
        await faces.settled()
        #expect(faces.revision == 1)
    }

    // MARK: - The widget

    private let entries = [
        ChatDirectoryEntry(id: "!a", name: "A", accountID: "one"),
        ChatDirectoryEntry(id: "!b", name: "B", accountID: "one", isPinned: true),
        ChatDirectoryEntry(id: "!c", name: "C", accountID: "two", isPinned: true),
        ChatDirectoryEntry(id: "!d", name: "D", accountID: "one"),
        ChatDirectoryEntry(id: "!e", name: "E", accountID: "one", isPinned: true),
    ]

    @Test("with nothing chosen: this account's pinned chats, then the top of its list")
    func defaultFill() {
        let filled = WidgetChats.fill(entries, chosen: [], count: 3, account: "one")
        #expect(filled.map(\.id) == ["!b", "!e", "!a"])
    }

    @Test("chosen chats in their order, any account, and a vanished one leaves no hole")
    func chosenFill() {
        let filled = WidgetChats.fill(entries, chosen: ["two|!c", "one|!gone", "one|!a"], count: 4, account: "one")
        #expect(filled.map(\.entityID) == ["two|!c", "one|!a"])
    }

    @Test("an unknown active account falls back to everybody's chats")
    func unknownAccount() {
        let filled = WidgetChats.fill(entries, chosen: [], count: 2, account: "nobody")
        #expect(filled.map(\.id) == ["!b", "!c"])
    }

    @Test("the widget is redrawn for what it shows, and not for anything else")
    func fingerprint() {
        let base = WidgetChats.fingerprint(entries, chosen: [], account: "one", locked: false)
        #expect(base == WidgetChats.fingerprint(entries, chosen: [], account: "one", locked: false))
        // Locking hides everything: a redraw.
        #expect(base != WidgetChats.fingerprint(entries, chosen: [], account: "one", locked: true))

        // A new picture, or unread news, on a chat it shows: a redraw.
        var changed = entries
        changed[0] = ChatDirectoryEntry(id: "!a", name: "A", accountID: "one", faceFile: "a.jpg")
        #expect(base != WidgetChats.fingerprint(changed, chosen: [], account: "one", locked: false))
        changed = entries
        changed[0] = ChatDirectoryEntry(id: "!a", name: "A", accountID: "one", unreadCount: 3)
        #expect(base != WidgetChats.fingerprint(changed, chosen: [], account: "one", locked: false))

        // The tenth chat getting a message changes nothing on the widget.
        let long = entries + (0..<10).map { ChatDirectoryEntry(id: "!x\($0)", name: "X", accountID: "one") }
        var quieter = long
        quieter[14] = ChatDirectoryEntry(id: "!x9", name: "X", accountID: "one", unreadCount: 1)
        #expect(WidgetChats.fingerprint(long, chosen: [], account: "one", locked: false)
                == WidgetChats.fingerprint(quieter, chosen: [], account: "one", locked: false))
    }

    @Test("what widgets were set up with is remembered for a month")
    func chosenIsRemembered() throws {
        let defaults = try freshDefaults("chosen")
        let then = Date(timeIntervalSince1970: 1_000_000)
        WidgetChats.recordChosen(["one|!a"], in: defaults, now: then)
        #expect(WidgetChats.chosen(in: defaults, now: then.addingTimeInterval(3600)) == ["one|!a"])
        #expect(WidgetChats.chosen(in: defaults, now: then.addingTimeInterval(31 * 24 * 3600)).isEmpty)
    }

    @Test("a tapped activity's link opens its chat in its account")
    func openChatURL() throws {
        let url = AppEnvironment.openChatURL(roomID: "!room:matrix.org", accountID: "one")
        let request = try #require(ChatDirectory.OpenRequest(url: url))
        #expect(request.roomID == "!room:matrix.org")
        #expect(request.accountID == "one")
        #expect(ChatDirectory.OpenRequest(url: AppEnvironment.shareHandoffURL) == nil)
    }

    @Test("the widget's account: the active one, a chosen one, or everybody — and falling back")
    func widgetAccount() throws {
        let defaults = try freshDefaults("widgetAccount")
        ChatDirectory.writeDirectory(entries, to: defaults)
        ChatDirectory.recordActiveAccount("one", in: defaults)

        #expect(ChatDirectory.widgetAccountID(in: defaults) == "one")
        ChatDirectory.setWidgetAccount(.account("two"), in: defaults)
        #expect(ChatDirectory.widgetAccountID(in: defaults) == "two")
        ChatDirectory.setWidgetAccount(.all, in: defaults)
        #expect(ChatDirectory.widgetAccountID(in: defaults) == nil)
        // An account that has since signed out: the active one instead of an empty widget.
        ChatDirectory.setWidgetAccount(.account("gone"), in: defaults)
        #expect(ChatDirectory.widgetAccountID(in: defaults) == "one")
    }

    @Test("asking for a chat is announced, so the app looks even if it came to the front first")
    func openIsAnnounced() async throws {
        let defaults = try freshDefaults("announce")
        let heard = Task {
            for await _ in OpenRequestSignal.announcements() { return true }
            return false
        }
        // The observer is registered as the stream starts; give it a moment, then ask.
        try await Task.sleep(for: .milliseconds(100))
        ChatDirectory.requestOpen(roomID: "!room", in: defaults)
        let result = try await withTimeout(.seconds(2)) { await heard.value }
        #expect(result)
    }
}
