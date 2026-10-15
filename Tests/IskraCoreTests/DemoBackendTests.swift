import Foundation
import MatrixRustSDK
import Synchronization
import Testing
@testable import IskraCore

/// The demo server, driven by the real SDK and the app's own stores.
///
/// This is the only test that can say the demo works. Every piece of `MockHomeserver` is a guess
/// about what the SDK will ask and what it will accept, and a wrong guess does not fail loudly: a
/// sync the SDK does not like is retried in silence, and the screen simply stays empty. So the
/// test does what a person would — signs in, waits for the chat list, opens a chat, writes in it —
/// and holds each step to having happened.
@MainActor
@Suite("Demo backend", .serialized)
struct DemoBackendTests {
    @Test("signs in, lists the rooms, opens a chat, and gets an answer")
    func endToEnd() async throws {
        let root = FileManager.default.temporaryDirectory.appending(component: "iskra-demo-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        await MockHomeserver.shared.setReplyDelay(.milliseconds(300))
        let client = try await DemoBackend.makeClient(data: root.appending(component: "data"),
                                                      cache: root.appending(component: "cache"),
                                                      search: root.appending(component: "search"))
        #expect(try client.userId() == "@sasha:iskra.demo")

        let list = RoomListStore(client: client)
        try await list.start()
        defer { Task { await list.stop() } }

        // Every room in the demo, including the invitation, the space, and the one put away as
        // low priority — which this app files under archived.
        let arrived = await eventually { list.rooms.count + list.archivedRooms.count >= 9 }
        #expect(arrived, "rooms: \(list.rooms.map(\.name))")

        // The list goes up as soon as it has rooms in it (`RoomListStore.firstPaint`) and each row
        // is brought up to date as the sync touches it, so a row's details may land a pass after the
        // row itself. Waited for rather than read at once — and waited for with a deadline, so a row
        // the incremental rebuild had left stale for good would still fail here.
        let caughtUp = await eventually {
            list.rooms.first { $0.id == "!anya:iskra.demo" }?.hasUnread == true
                && list.rooms.contains { $0.isInvitation && $0.name.contains("Книжный") }
        }
        #expect(caughtUp)

        let anya = try #require(list.rooms.first { $0.id == "!anya:iskra.demo" })
        #expect(anya.isDirectMessage)
        #expect(anya.name == "Аня Смирнова")
        #expect(anya.hasUnread)
        #expect(list.rooms.contains { $0.isInvitation && $0.name.contains("Книжный") })
        #expect(list.rooms.contains { $0.isSpace })
        #expect(list.archivedRooms.contains { $0.name == "Лена Котова" })

        let room = try #require(list.room(withID: anya.id))
        let timeline = TimelineStore(room: room, ownUserID: "@sasha:iskra.demo")
        try await timeline.start()
        defer { timeline.stop() }

        let messages = { timeline.rows.compactMap { row -> Message? in
            if case let .message(message) = row { return message }
            return nil
        } }
        let loaded = await eventually { messages().count >= 10 }
        #expect(loaded, "rows: \(timeline.rows.count)")

        let kinds = messages().map(\.kind)
        #expect(kinds.contains { if case .image = $0 { true } else { false } })
        #expect(kinds.contains { if case .voice = $0 { true } else { false } })
        #expect(kinds.contains { if case .location = $0 { true } else { false } })
        #expect(kinds.contains { if case .file = $0 { true } else { false } })
        #expect(kinds.contains { if case .deleted = $0 { true } else { false } })
        #expect(messages().contains { $0.isEdited })

        // Writing: the message is sent, the server echoes it back, and somebody answers.
        let before = messages().count
        await timeline.send(text: "Проверка связи")
        let sent = await eventually {
            messages().contains { $0.isOwn && $0.kind == .text("Проверка связи") && ($0.delivery == .sent || $0.delivery == .read) }
        }
        #expect(sent, "last: \(messages().suffix(2).map(\.kind))")
        let answered = await eventually(seconds: 10) {
            messages().count >= before + 2 && messages().last?.isOwn == false
        }
        #expect(answered)

        // And history, a page at a time, in the long room.
        let devRoom = try #require(list.room(withID: "!iskra-dev:iskra.demo"))
        let dev = TimelineStore(room: devRoom, ownUserID: "@sasha:iskra.demo")
        try await dev.start()
        defer { dev.stop() }
        _ = await eventually { dev.hasLoaded }
        let firstPage = dev.rows.count
        await dev.loadMoreHistory()
        let paged = await eventually { dev.rows.count > firstPage }
        #expect(paged, "first page: \(firstPage), after: \(dev.rows.count)")

        // And nothing the SDK asked for along the way fell through to "unrecognized".
        #expect(await MockHomeserver.shared.unrecognized.isEmpty)
    }

    /// The rest of what the screens do, through a whole `UserSession` started the way the app
    /// starts one: an invitation, a new chat, a space, a reaction, a new name, and recovery.
    @Test("the session's other paths all reach an answer")
    func sessionPaths() async throws {
        let root = FileManager.default.temporaryDirectory.appending(component: "iskra-demo-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        await MockHomeserver.shared.setReplyDelay(.milliseconds(300))
        let client = try await DemoBackend.makeClient(data: root.appending(component: "data"),
                                                      cache: root.appending(component: "cache"),
                                                      search: root.appending(component: "search"))
        let session = UserSession(client: client, authentication: AuthenticationService(), sessionID: "demo", isDemo: true)
        try await session.start()
        defer { Task { await session.close() } }
        #expect(await eventually { session.roomList.rooms.count >= 8 })
        #expect(session.displayName == "Саша")

        // The invitation, accepted.
        await session.roomList.accept(roomID: "!books:iskra.demo")
        #expect(await eventually {
            session.roomList.rooms.contains { $0.id == "!books:iskra.demo" && !$0.isInvitation }
        })

        // A space and what is in it — including the room this account is not in yet.
        let space = session.space(forRoomID: "!work:iskra.demo")
        await space.load()
        #expect(Set(space.rooms.map(\.name)) == ["Общий", "Офтоп"])

        // A new chat, which the app makes encrypted: the message has to come back readable, and
        // the person invited has to turn up and answer.
        let dmID = try await session.createDirectChat(with: "@dima:iskra.demo")
        let dm = try #require(session.timeline(forRoomID: dmID))
        try await dm.start()
        await dm.send(text: "Привет, Дима")
        let messages = { dm.rows.compactMap { row -> Message? in
            if case let .message(message) = row { return message }
            return nil
        } }
        #expect(await eventually { messages().contains { $0.isOwn && $0.kind == .text("Привет, Дима") } },
                "rows: \(messages().map(\.kind))")
        #expect(await eventually(seconds: 10) { messages().contains { !$0.isOwn } })

        // A reaction on somebody else's message.
        let family = try #require(session.timeline(forRoomID: "!family:iskra.demo"))
        try await family.start()
        #expect(await eventually { family.hasLoaded })
        let target = try #require(family.rows.compactMap { row -> Message? in
            if case let .message(message) = row, !message.isOwn { return message }
            return nil
        }.last)
        await family.toggleReaction(messageID: target.id, key: "🌻")
        #expect(await eventually {
            family.rows.contains { row in
                if case let .message(message) = row { message.reactions.contains { $0.key == "🌻" && $0.isMine } } else { false }
            }
        })

        // A new name.
        try await session.rename(to: "Александра")
        #expect(session.displayName == "Александра")

        // And recovery, which is the SDK's secret storage and key backup end to end.
        await session.recovery.waitForSetup()
        let key = await session.recovery.protectHistory()
        #expect(key != nil, "failure: \(String(describing: session.recovery.failure))")

        let unrecognized = await MockHomeserver.shared.unrecognized
        #expect(unrecognized.isEmpty, "\(unrecognized)")
    }

    /// The chat list's peek, held to the one promise it makes: looking is not reading.
    ///
    /// Here, through the demo server, because the promise is about what goes over the wire — a
    /// receipt is a request to the homeserver, and nothing short of a homeserver can say whether
    /// one was sent. And in this suite rather than one of its own, because the server is one per
    /// process: two suites driving it at once time each other out. The last step presses "read" on
    /// purpose and watches the receipt move, so that a test which could not see receipts at all
    /// would fail there instead of passing everything above it.
    @Test("peeking at a chat, history included, sends no read receipt")
    func peekingReadsNothing() async throws {
        let root = FileManager.default.temporaryDirectory.appending(component: "iskra-peek-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let client = try await DemoBackend.makeClient(data: root.appending(component: "data"),
                                                      cache: root.appending(component: "cache"),
                                                      search: root.appending(component: "search"))
        let session = UserSession(client: client, authentication: AuthenticationService(), sessionID: "demo", isDemo: true)
        try await session.start()
        defer { Task { await session.close() } }

        // Миша writes, so there is something to leave unread whatever ran before this.
        let roomID = "!misha:iskra.demo"
        let me = "@sasha:iskra.demo"
        await MockHomeserver.shared.say("Ты тут?", in: roomID, from: "@misha:iskra.demo")
        #expect(await eventually { session.roomList.rooms.first { $0.id == roomID }?.hasUnread == true })
        let before = await MockHomeserver.shared.receipt(of: me, in: roomID)
        #expect(before != nil)

        let peek = try #require(session.peekTimeline(forRoomID: roomID))
        try await peek.start()
        #expect(await eventually { peek.hasLoaded && !peek.rows.isEmpty })
        // And further back, the way scrolling the card does.
        await peek.loadMoreHistory()
        // Long enough for anything the opening might have queued to reach the server.
        try await Task.sleep(for: .seconds(1))
        peek.stop()

        #expect(await MockHomeserver.shared.receipt(of: me, in: roomID) == before)
        #expect(session.roomList.rooms.first { $0.id == roomID }?.hasUnread == true)

        // Not a store the room screen would be handed, either — see `peekTimeline(forRoomID:)`.
        let screen = try #require(session.timeline(forRoomID: roomID))
        #expect(screen !== peek)

        // The control: reading *does* move it, so the checks above were able to fail.
        try await screen.start()
        #expect(await eventually { screen.hasLoaded })
        await screen.markAsRead()
        let moved = await eventually(async: { await MockHomeserver.shared.receipt(of: me, in: roomID) != before })
        #expect(moved)
        screen.stop()
    }

    /// Stickers through the real SDK: the account's pack from account data, the room's from its
    /// state over the app's own request, a sent one arriving as a sticker, and a received one added.
    @Test("a poll is drawn with its tally, takes a vote, and closes")
    func polls() async throws {
        let root = FileManager.default.temporaryDirectory.appending(component: "iskra-poll-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let client = try await DemoBackend.makeClient(data: root.appending(component: "data"),
                                                      cache: root.appending(component: "cache"),
                                                      search: root.appending(component: "search"))
        let session = UserSession(client: client, authentication: AuthenticationService(), sessionID: "demo", isDemo: true)
        try await session.start()
        defer { Task { await session.close() } }
        let devID = "!iskra-dev:iskra.demo"
        _ = await eventually { session.roomList.rooms.contains { $0.id == devID } }

        let timeline = try #require(session.timeline(forRoomID: devID))
        try await timeline.start()
        defer { timeline.stop() }

        func poll() -> (id: String, poll: Poll)? {
            for row in timeline.rows {
                if case let .message(message) = row, case let .poll(poll) = message.kind { return (message.id, poll) }
            }
            return nil
        }
        let found = await eventually(async: {
            if poll() == nil { await timeline.loadMore() }
            return poll()?.poll.voters == 2
        })
        #expect(found, "poll: \(String(describing: poll()?.poll))")
        let (id, before) = try #require(poll())
        #expect(before.question == "Когда созвонимся на неделе?")
        #expect(before.answers.map(\.text) == ["Во вторник", "В среду", "В четверг"])
        #expect(!before.hasVoted && !before.showsResults)

        await timeline.vote(inPoll: id, answerIDs: ["a1"])
        #expect(timeline.failure == nil)
        let voted = await eventually {
            guard let poll = poll()?.poll else { return false }
            return poll.voters == 3 && poll.answers[1].isChosen && poll.answers[1].votes == 2
        }
        #expect(voted, "poll: \(String(describing: poll()?.poll))")
        #expect(poll()?.poll.showsResults == true)

        // Not ours to close — Лена started it. One of our own is.
        await timeline.send(poll: {
            var draft = PollDraft()
            draft.question = "Пицца или суши?"
            draft.answers = ["Пицца", "Суши", ""]
            return draft
        }())
        let ownID = await eventually {
            timeline.rows.contains { row in
                if case let .message(message) = row, message.canEndPoll,
                   case let .poll(poll) = message.kind { return poll.question == "Пицца или суши?" }
                return false
            }
        }
        #expect(ownID)
        let own = try #require(timeline.rows.compactMap { row -> Message? in
            if case let .message(message) = row, message.canEndPoll { return message }
            return nil
        }.first)
        await timeline.endPoll(own.id)
        let ended = await eventually {
            timeline.rows.contains { row in
                if case let .message(message) = row, message.id == own.id, case let .poll(poll) = message.kind {
                    return poll.isEnded
                }
                return false
            }
        }
        #expect(ended)
        #expect(await MockHomeserver.shared.unrecognized.isEmpty)
    }

    @Test("an administrator hands a rule to the moderators, and the room keeps it")
    func roomRules() async throws {
        let root = FileManager.default.temporaryDirectory.appending(component: "iskra-rules-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let client = try await DemoBackend.makeClient(data: root.appending(component: "data"),
                                                      cache: root.appending(component: "cache"),
                                                      search: root.appending(component: "search"))
        let session = UserSession(client: client, authentication: AuthenticationService(), sessionID: "demo", isDemo: true)
        try await session.start()
        defer { Task { await session.close() } }
        let devID = "!iskra-dev:iskra.demo"
        _ = await eventually { session.roomList.rooms.contains { $0.id == devID } }

        let details = try #require(session.details(forRoomID: devID))
        await details.load()
        defer { details.stop() }
        let loaded = await eventually { details.rules != nil && !details.members.isEmpty }
        #expect(loaded)
        #expect(details.permissions.canChangeRoles)
        #expect(details.staff.contains { $0.id == "@sasha:iskra.demo" })

        let before = try #require(details.rules?.role(for: .ban))
        let target: RoomRole = before == .moderator ? .administrator : .moderator
        #expect(details.roles(for: .ban).contains(target))
        await details.setRule(.ban, to: target)
        #expect(details.failure == nil)

        // Read back from the room, not from what the store put on the screen.
        _ = await eventually { details.rules?.role(for: .ban) == target }
        let again = try #require(session.details(forRoomID: devID))
        await again.load()
        defer { again.stop() }
        let kept = await eventually { again.rules?.role(for: .ban) == target }
        // And the screen that made the change kept showing it — it was not put back by a stale read.
        #expect(details.rules?.role(for: .ban) == target, "before: \(before), now: \(String(describing: details.rules?.levels[.ban]))")
        #expect(kept, "ban: \(String(describing: again.rules?.levels[.ban]))")
        #expect(await MockHomeserver.shared.unrecognized.isEmpty)
    }

    @Test("stickers: packs are read, one is sent, and one somebody sent is added")
    func stickers() async throws {
        let root = FileManager.default.temporaryDirectory.appending(component: "iskra-stickers-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let client = try await DemoBackend.makeClient(data: root.appending(component: "data"),
                                                      cache: root.appending(component: "cache"),
                                                      search: root.appending(component: "search"))
        let session = UserSession(client: client, authentication: AuthenticationService(), sessionID: "demo", isDemo: true)
        try await session.start()
        defer { Task { await session.close() } }
        let devID = "!iskra-dev:iskra.demo"
        _ = await eventually { session.roomList.rooms.contains { $0.id == devID } }

        // The account data arrives with sync, so the first load may come before it does.
        let library = session.stickers
        let loaded = await eventually(async: {
            await library.load(roomID: devID)
            return library.packs.count == 3
        })
        #expect(loaded, "\(library.packs.map { ($0.name, $0.stickers.count) })")
        #expect(library.packs.first?.isMine == true)
        #expect(library.packs.first?.stickers.count == 4)
        #expect(library.packs.dropFirst().first?.name == "Искра")
        // And the app's own, last, uploaded to the demo server on this first opening.
        #expect(library.packs.last?.isBuiltIn == true)
        #expect(library.packs.last?.stickers.count == StickerArt.allCases.count)

        // Sent from the room's pack, it comes back as a sticker with its description.
        let timeline = try #require(session.timeline(forRoomID: devID))
        try await timeline.start()
        defer { timeline.stop() }
        let sticker = try #require(library.packs.first { $0.name == "Искра" }?.stickers.first { $0.body == "🏃" })
        await timeline.send(sticker: sticker)
        #expect(timeline.failure == nil)
        let arrived = await eventually {
            timeline.rows.contains { row in
                guard case let .message(message) = row, message.isOwn,
                      case let .sticker(attachment) = message.kind else { return false }
                return attachment.mediaID == sticker.url && attachment.caption == "🏃"
            }
        }
        #expect(arrived)

        // Миша's sticker is the room pack's and not ours — until it is added.
        let misha = try #require(session.timeline(forRoomID: "!misha:iskra.demo"))
        try await misha.start()
        defer { misha.stop() }
        var received: IskraCore.Attachment?
        _ = await eventually {
            received = misha.rows.lazy.compactMap { row -> IskraCore.Attachment? in
                guard case let .message(message) = row, case let .sticker(attachment) = message.kind else { return nil }
                return attachment
            }.first
            return received != nil
        }
        let theirs = try #require(received?.asSticker)
        #expect(!library.isMine(theirs.url))
        await library.add(theirs)
        #expect(library.failure == nil)
        #expect(library.isMine(theirs.url))
        #expect(library.packs.first?.stickers.count == 5)

        let unrecognized = await MockHomeserver.shared.unrecognized
        #expect(unrecognized.isEmpty, "\(unrecognized)")
    }

    /// A WebP picked as a photo goes as a sticker. The demo's rooms are not encrypted, so this is
    /// the `m.sticker` way — uploaded, pointed at, and plain enough for anybody to keep.
    @Test("a WebP sent as a photo arrives as a sticker")
    func webPIsASticker() async throws {
        let root = FileManager.default.temporaryDirectory.appending(component: "iskra-webp-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let client = try await DemoBackend.makeClient(data: root.appending(component: "data"),
                                                      cache: root.appending(component: "cache"),
                                                      search: root.appending(component: "search"))
        let session = UserSession(client: client, authentication: AuthenticationService(), sessionID: "demo", isDemo: true)
        try await session.start()
        defer { Task { await session.close() } }
        let devID = "!iskra-dev:iskra.demo"
        _ = await eventually { session.roomList.rooms.contains { $0.id == devID } }

        let timeline = try #require(session.timeline(forRoomID: devID))
        try await timeline.start()
        defer { timeline.stop() }

        await timeline.send(photo: StickerFixtures.webP, filename: "IMG_0001.webp")
        #expect(timeline.failure == nil)
        let arrived = await eventually {
            timeline.rows.contains { row in
                guard case let .message(message) = row, message.isOwn,
                      case let .sticker(attachment) = message.kind else { return false }
                return attachment.mimeType == "image/webp" && attachment.asSticker != nil
            }
        }
        #expect(arrived)

        let unrecognized = await MockHomeserver.shared.unrecognized
        #expect(unrecognized.isEmpty, "\(unrecognized)")
    }

    /// The row of a chat on the screen reads the chat itself — see `RoomPeek`. Three things the
    /// SDK's own summary cannot say, each made to happen on the server with the chat *closed*: a
    /// message of yours read on the other side, a message taken back, and a grey line.
    @Test("a row on the screen shows the read mark, a deleted message and a grey line")
    func rowReadsTheChat() async throws {
        let root = FileManager.default.temporaryDirectory.appending(component: "iskra-rowpeek-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let client = try await DemoBackend.makeClient(data: root.appending(component: "data"),
                                                      cache: root.appending(component: "cache"),
                                                      search: root.appending(component: "search"))
        let session = UserSession(client: client, authentication: AuthenticationService(), sessionID: "demo", isDemo: true)
        try await session.start()
        defer { Task { await session.close() } }

        let roomID = "!misha:iskra.demo"
        let me = "@sasha:iskra.demo"
        let misha = "@misha:iskra.demo"
        let list = session.roomList
        #expect(await eventually { list.rooms.contains { $0.id == roomID } })
        list.rowAppeared(roomID)
        defer { list.rowDisappeared(roomID) }
        let row = { list.rooms.first { $0.id == roomID } }

        let mine = await MockHomeserver.shared.append(roomID, sender: me, type: "m.room.message",
                                                      content: ["msgtype": "m.text", "body": "Встретимся в шесть"])
        #expect(await eventually { row()?.lastMessage == "Встретимся в шесть" })
        await MockHomeserver.shared.read(roomID, by: misha, upTo: mine)
        #expect(await eventually { row()?.lastMessageMark == .read }, "\(String(describing: row()))")

        let theirs = await MockHomeserver.shared.append(roomID, sender: misha, type: "m.room.message",
                                                        content: ["msgtype": "m.text", "body": "Ой, не туда"])
        #expect(await eventually { row()?.lastMessage == "Ой, не туда" })
        _ = await MockHomeserver.shared.append(roomID, sender: misha, type: "m.room.redaction",
                                               content: ["redacts": theirs], extra: ["redacts": theirs])
        let deleted = MessagePreview.text(for: .deleted)
        #expect(await eventually { row()?.lastMessage == deleted }, "\(String(describing: row()?.lastMessage))")

        _ = await MockHomeserver.shared.append(roomID, sender: misha, type: "m.room.member",
                                               content: ["membership": "join", "displayname": "Михаил"],
                                               stateKey: misha)
        #expect(await eventually { row()?.lastMessage?.contains("Михаил") == true },
                "\(String(describing: row()?.lastMessage))")
    }

    private func eventually(seconds: Double = 15, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return condition()
    }

    /// A file sent and then deleted at once — which is what every caller does: the Share outbox's
    /// `defer`, the picked file's security scope, the stripped copy of a video. The send returns
    /// before the SDK has read the file, and the question is whether the SDK has its own copy by
    /// then or reads the path later, from a queue task, when the file may already be gone.
    @Test("a file deleted the moment it is sent still arrives")
    func fileDeletedAfterSendArrives() async throws {
        let root = FileManager.default.temporaryDirectory.appending(component: "iskra-demo-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let client = try await DemoBackend.makeClient(data: root.appending(component: "data"),
                                                      cache: root.appending(component: "cache"),
                                                      search: root.appending(component: "search"))
        let list = RoomListStore(client: client)
        try await list.start()
        defer { Task { await list.stop() } }
        _ = await eventually { list.room(withID: "!anya:iskra.demo") != nil }
        let room = try #require(list.room(withID: "!anya:iskra.demo"))
        let timeline = TimelineStore(room: room, ownUserID: "@sasha:iskra.demo")
        try await timeline.start()
        defer { timeline.stop() }

        let file = root.appending(component: "notes-\(UUID().uuidString.prefix(6)).txt")
        try Data(repeating: 0x41, count: 64 * 1024).write(to: file)
        await timeline.send(file: file)
        try FileManager.default.removeItem(at: file)

        let sent = await eventually(seconds: 10) {
            timeline.rows.contains { row in
                guard case let .message(message) = row, message.isOwn,
                      case let .file(attachment) = message.kind,
                      attachment.filename == file.lastPathComponent else { return false }
                return message.delivery == .sent || message.delivery == .read
            }
        }
        let failed = timeline.rows.contains { row in
            guard case let .message(message) = row, message.isOwn,
                  case .file = message.kind, case .failed = message.delivery else { return false }
            return true
        }
        #expect(sent, "failed: \(failed)")
    }

    /// The Share outbox, sent: into a room this account knows it all goes and its copy with it;
    /// into one it does not, the copy goes and nothing comes back to be retried for ever.
    @Test("what the Share sheet queued is sent, or thrown away when it never can be")
    func outboxItemsAreSentOrDropped() async throws {
        let root = FileManager.default.temporaryDirectory.appending(component: "iskra-demo-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let client = try await DemoBackend.makeClient(data: root.appending(component: "data"),
                                                      cache: root.appending(component: "cache"),
                                                      search: root.appending(component: "search"))
        // A container of the test's own: the real App Group is the user's, and an unsigned test
        // binary is refused it anyway.
        let environment = AppEnvironment(storage: .scratch(root.appending(component: "container")))
        let session = UserSession(client: client, authentication: AuthenticationService(environment: environment),
                                  sessionID: "demo", isDemo: true)
        try await session.start()
        defer { Task { await session.close() } }
        _ = await eventually { session.roomList.room(withID: "!anya:iskra.demo") != nil }

        let outbox = try ChatDirectory.outboxFolder(environment: environment)
        func queuedCopy() throws -> (ChatDirectory.OutboxAttachment, URL) {
            let slot = "test-\(UUID().uuidString)"
            let folder = outbox.appending(component: slot)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(repeating: 0x41, count: 1024).write(to: folder.appending(component: "notes.txt"))
            return (ChatDirectory.OutboxAttachment(kind: .file, filename: "\(slot)/notes.txt"), folder)
        }

        let (sent, sentFolder) = try queuedCopy()
        let item = ChatDirectory.OutboxItem(roomID: "!anya:iskra.demo", text: "вот, смотри", attachments: [sent])
        #expect(await session.sendQueued(item) == nil)
        #expect(!FileManager.default.fileExists(atPath: sentFolder.path(percentEncoded: false)))

        let (lost, lostFolder) = try queuedCopy()
        let nowhere = ChatDirectory.OutboxItem(roomID: "!nobody:iskra.demo", text: "эй", attachments: [lost])
        #expect(await session.sendQueued(nowhere) == nil)
        #expect(!FileManager.default.fileExists(atPath: lostFolder.path(percentEncoded: false)))
    }

    /// Somebody's keys changed: they are on the list, by name; the change answered — pinned, or
    /// verified again — takes them off; the account's own identity is not a warning about anyone.
    /// Fed the SDK's own values, because making the demo server re-key a person would mean faking
    /// cross-signing, and the subscription itself is still started against the real SDK.
    @Test("a changed identity is a warning, by name, until it is answered")
    func identityChangesAreListed() async throws {
        let root = FileManager.default.temporaryDirectory.appending(component: "iskra-demo-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let client = try await DemoBackend.makeClient(data: root.appending(component: "data"),
                                                      cache: root.appending(component: "cache"),
                                                      search: root.appending(component: "search"))
        let list = RoomListStore(client: client)
        try await list.start()
        defer { Task { await list.stop() } }
        _ = await eventually { list.room(withID: "!anya:iskra.demo") != nil }
        let room = try #require(list.room(withID: "!anya:iskra.demo"))

        let store = IdentityChangesStore(room: room, encryption: client.encryption(), ownUserID: "@sasha:iskra.demo")
        await store.start()
        defer { store.stop() }
        #expect(store.changes.isEmpty)

        await store.apply([IdentityStatusChange(userId: "@anya:iskra.demo", changedTo: .pinViolation),
                           IdentityStatusChange(userId: "@sasha:iskra.demo", changedTo: .pinViolation)])
        #expect(store.changes == [IdentityChange(userID: "@anya:iskra.demo", name: "Аня Смирнова", kind: .changed)])

        await store.apply([IdentityStatusChange(userId: "@anya:iskra.demo", changedTo: .verificationViolation)])
        #expect(store.changes.map(\.kind) == [.changedAfterVerification])

        await store.apply([IdentityStatusChange(userId: "@anya:iskra.demo", changedTo: .pinned)])
        #expect(store.changes.isEmpty)
    }

    /// `stop()` while `start()` is still on its way: an account switched on a cold launch from a
    /// push, the bridge changed while the first request hung. `start()` used to carry on and end
    /// in `service.start()` — a sync loop for a closed session that nothing would ever stop.
    ///
    /// Last in the suite on purpose: the demo server is one shared world, and a second client
    /// starting and stopping in it made the tests after it miss their answers now and then.
    @Test("a stop during start leaves no sync loop behind")
    func stopDuringStart() async throws {
        let root = FileManager.default.temporaryDirectory.appending(component: "iskra-demo-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let client = try await DemoBackend.makeClient(data: root.appending(component: "data"),
                                                      cache: root.appending(component: "cache"),
                                                      search: root.appending(component: "search"))

        let list = RoomListStore(client: client)
        // Let `start()` run up to its first wait on the SDK, *then* stop — the other order is an
        // ordinary stop followed by an ordinary start.
        let starting = Task { @MainActor in try await list.start() }
        await Task.yield()
        await Task.yield()
        await list.stop()
        try? await starting.value
        #expect(list.currentSyncService == nil)

        try await Task.sleep(for: .seconds(1))
        #expect(list.currentSyncService == nil)

        // And the store is not wedged by it: the next start is a real one.
        try await list.start()
        let service = try #require(list.currentSyncService)

        // Into a pocket and straight back out, faster than the SDK can stop: the resume used to
        // start the loop before the pause's stop had landed, and the stop then won — `.idle`, with
        // nothing that would ever start it again.
        let states = SyncStates()
        let watching = service.state(listener: states)
        defer { watching.cancel() }
        // The observer says nothing until the loop changes, so a slow round first — which is
        // also the ordinary pocket and back, and has to keep working.
        await list.pause()
        #expect(await eventually(seconds: 5) { states.last == .idle })
        await list.resume()
        #expect(await eventually(seconds: 5) { states.last == .running })

        let pausing = Task { @MainActor in await list.pause() }
        await Task.yield()
        await list.resume()
        await pausing.value
        try await Task.sleep(for: .milliseconds(500))
        #expect(states.last == .running, "\(states.all)")

        await list.stop()
    }

    private final class SyncStates: SyncServiceStateObserver, Sendable {
        private let seen = Mutex<[SyncServiceState]>([])
        var last: SyncServiceState? { seen.withLock { $0.last } }
        var all: [SyncServiceState] { seen.withLock { $0 } }
        func onUpdate(state: SyncServiceState) { seen.withLock { $0.append(state) } }
    }

    private func eventually(seconds: Double = 15, async condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return await condition()
    }
}
