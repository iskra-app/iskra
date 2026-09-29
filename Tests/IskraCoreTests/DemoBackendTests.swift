import Foundation
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
    /// `stop()` while `start()` is still on its way: an account switched on a cold launch from a
    /// push, the bridge changed while the first request hung. `start()` used to carry on and end
    /// in `service.start()` — a sync loop for a closed session that nothing would ever stop.
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
        #expect(list.currentSyncService != nil)
        await list.stop()
    }

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

    private func eventually(seconds: Double = 15, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return condition()
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
