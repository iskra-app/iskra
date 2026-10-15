import Foundation

/// A Matrix homeserver that lives inside the app, for looking at every screen without an account.
///
/// It is an `HTTPUpstream`, which is the whole trick: `LocalHTTPProxy` already puts a plain-HTTP
/// listener on loopback for the SDK to talk to, and this answers what arrives there instead of
/// forwarding it. So the demo is **the real app** — the real SDK, the real sliding sync, the real
/// stores and timelines and send queue — talking to a server that happens to be made up. Nothing
/// above `IskraCore` knows the difference, and nothing had to be taught to pretend.
///
/// It speaks exactly as much of the client-server API as the app uses, and no more: password
/// login, simplified sliding sync (MSC4186) with long-polling, history, sending, editing,
/// reactions, redaction, receipts, typing, state, members, invites, joining and leaving, spaces,
/// the directory, profiles, media, push rules, account data, and enough of the key endpoints for
/// the SDK's crypto to set itself up and be satisfied. Rooms are **not encrypted**: the people in
/// them are made up and have no devices, and a message nobody can decrypt is not a demo.
///
/// State is in memory. It survives turning the demo off and on again within one launch and is
/// rebuilt from `MockWorld` at the next; the demo's SDK store is thrown away at the same moments,
/// so the two never disagree about what happened.
///
/// Nothing here goes near the network, and the server name is under `.invalid`-style `iskra.demo`
/// — no real homeserver can ever be addressed by it.
public actor MockHomeserver: HTTPUpstream {
    public static let serverName = "iskra.demo"

    /// One server per process. Turning the demo off and on again finds the same conversations.
    public static let shared = MockHomeserver()

    typealias JSON = [String: Any]

    struct Room {
        let id: String
        /// Every event in the room, oldest first, state included.
        var events: [JSON] = []
        /// The current state, keyed by `type` + NUL + `state_key`.
        var state: [String: JSON] = [:]
        /// Room account data by type: tags, `m.fully_read`.
        var accountData: [String: JSON] = [:]
        /// Read receipts, by user: the event they have read up to and when.
        var receipts: [String: (eventID: String, ts: Int)] = [:]
        var typing: Set<String> = []
        /// Bumped by anything a sync should carry: an event, a receipt, typing, account data.
        var revision = 0
    }

    struct Profile {
        var name: String
        var avatar: String?
    }

    /// What one sliding-sync `pos` has already been told. A response is always the difference
    /// between the world now and the snapshot its request names.
    struct Snapshot {
        var delivered: [String: Int] = [:]      // room → events delivered
        var revisions: [String: Int] = [:]      // room → revision delivered
        var joined: Set<String> = []            // rooms delivered as joined
        var invited: Set<String> = []           // rooms delivered as invitations
        var accountData = -1
    }

    // MARK: - State

    let me: String
    var rooms: [String: Room] = [:]
    var profiles: [String: Profile] = [:]
    var globalAccountData: [String: JSON] = [:]
    var accountDataRevision = 0
    /// Bumped on every change at all; a waiting sync wakes when it moves.
    var revision = 0
    var positions: [Int: Snapshot] = [:]
    var nextPosition = 1
    var media: [String: (data: Data, mime: String)] = [:]
    var sentTransactions: [String: String] = [:]
    var publicRoomIDs: [String] = []
    /// Addresses made on this server, `#name:server` → room ID. The rooms' own `canonical_alias` is
    /// state; this is the server's table that makes the address resolve.
    var aliases: [String: String] = [:]

    // Keys, which the SDK insists on setting up whether or not anybody encrypts anything.
    var deviceID = "IKSRADEMO"
    /// The demo account's *other* sessions, for the Devices screen to have something on it — and
    /// something to end. Removed for good when ended; the server's memory lasts one launch.
    var otherDevices: [JSON] = [
        ["device_id": "MACBOOKDEMO", "display_name": "Iskra/1.0 (MacBook Air; macOS 26.0)",
         "last_seen_ts": Int(Date().addingTimeInterval(-3 * 3600).timeIntervalSince1970 * 1000),
         "last_seen_ip": "93.184.216.34"],
        ["device_id": "WEBDEMO", "display_name": "Element Web: Firefox on Linux",
         "last_seen_ts": Int(Date().addingTimeInterval(-6 * 86_400).timeIntervalSince1970 * 1000),
         "last_seen_ip": "198.51.100.7"],
    ]
    var deviceKeys: JSON?
    var crossSigning: [String: JSON] = [:]
    var oneTimeKeys = 0
    var backup: JSON?
    var backupKeys = 0

    /// How long a reply takes to arrive, so that "typing…" is long enough to see.
    var replyDelay: Duration = .seconds(3)

    /// Every request that fell through to "unrecognized", for the test to show.
    private(set) var unrecognized: [String] = []

    func setReplyDelay(_ delay: Duration) {
        replyDelay = delay
    }

    /// While set, a sync request is taken and never answered — the connection that died in a pocket,
    /// as the SDK sees it. For `DemoBackendTests.recoversFromAHungSync`.
    private(set) var holdsSync = false

    func setHoldsSync(_ holds: Bool) {
        holdsSync = holds
    }

    /// The event a user's read receipt stands on in a room — for `DemoBackendTests`, which has to see
    /// that looking at a chat did not move it.
    func receipt(of user: String, in roomID: String) -> String? {
        rooms[roomID]?.receipts[user]?.eventID
    }

    /// Somebody else writes into a room, so that there is something unread in it — for the same
    /// test, which cannot count on the demo's own unread messages: an earlier test renames the
    /// account, and a new name is an event from *you* in every room, which reads them all.
    func say(_ text: String, in roomID: String, from sender: String) {
        append(roomID, sender: sender, type: "m.room.message", content: ["msgtype": "m.text", "body": text])
    }

    init() {
        let world = MockWorld()
        me = world.me
        rooms = world.rooms
        profiles = world.profiles
        globalAccountData = world.accountData
        media = world.media
        publicRoomIDs = world.publicRoomIDs
    }

    // MARK: - HTTPUpstream

    public func send(_ request: ProxiedRequest) async throws -> ProxiedResponse {
        let (path, query) = Self.split(request.target)
        let body = (try? JSONSerialization.jsonObject(with: request.body)) as? JSON ?? [:]

        do {
            if let response = try await route(request.method, path, query, body, raw: request) {
                return response
            }
        } catch let failure as Failure {
            return failure.response
        }

        // Written down, because an endpoint the demo does not know is the first thing to look
        // for when a screen in it misbehaves. Paths carry room and event IDs — made-up ones.
        unrecognized.append("\(request.method) \(path.joined(separator: "/"))")
        Log.session.info("demo server: nothing at \(request.method, privacy: .public) \(path.joined(separator: "/"), privacy: .public)")
        return Self.error(404, "M_UNRECOGNIZED", "Unrecognized request")
    }

    struct Failure: Error {
        let response: ProxiedResponse
        init(_ status: Int, _ code: String, _ message: String = "") {
            response = MockHomeserver.error(status, code, message)
        }
    }

    // MARK: - Directory

    /// `directory/room/{alias}` — the address table — and `directory/list/room/{id}`, whether the
    /// room is in the public list.
    private func directory(_ method: String, _ rest: [String], _ body: JSON) -> ProxiedResponse {
        if rest.count == 2, rest[0] == "room" {
            let alias = rest[1].removingPercentEncoding ?? rest[1]
            switch method {
            case "GET":
                guard let id = aliases[alias] else { return Self.error(404, "M_NOT_FOUND", "Room alias not found") }
                return Self.ok(["room_id": id, "servers": [Self.serverName]])
            case "PUT":
                guard aliases[alias] == nil else { return Self.error(409, "M_UNKNOWN", "Room alias already exists") }
                aliases[alias] = body["room_id"] as? String ?? ""
                return Self.ok([:])
            case "DELETE":
                guard aliases.removeValue(forKey: alias) != nil else { return Self.error(404, "M_NOT_FOUND") }
                return Self.ok([:])
            default:
                break
            }
        }
        if rest.count == 3, rest[0] == "list", rest[1] == "room" {
            let id = rest[2].removingPercentEncoding ?? rest[2]
            if method == "GET" {
                return Self.ok(["visibility": publicRoomIDs.contains(id) ? "public" : "private"])
            }
            if method == "PUT" {
                publicRoomIDs.removeAll { $0 == id }
                if (body["visibility"] as? String) == "public" { publicRoomIDs.append(id) }
                revision += 1
                return Self.ok([:])
            }
        }
        return Self.error(404, "M_UNRECOGNIZED")
    }

    // MARK: - Routing

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private func route(_ method: String, _ path: [String], _ query: [String: String], _ body: JSON,
                       raw: ProxiedRequest) async throws -> ProxiedResponse? {
        guard path.count >= 2, path[0] == "_matrix" else {
            return path.first == ".well-known" ? Self.error(404, "M_NOT_FOUND") : nil
        }

        // Media, under either the old or the authenticated prefix.
        if path[1] == "media" || (path.count > 3 && path[1] == "client" && path[3] == "media") {
            return try mediaRoute(method, Array(path.dropFirst(path[1] == "media" ? 3 : 4)), query, raw)
        }
        guard path[1] == "client" else { return nil }
        if path.count == 3, path[2] == "versions" { return Self.ok(Self.versions) }

        let segments = Array(path.dropFirst(3))   // after `/_matrix/client/<version>/`
        let head = segments.first ?? ""

        switch (method, head) {
        case ("GET", "login"):
            return Self.ok(["flows": [["type": "m.login.password"]]])
        case ("POST", "login"):
            // Every demo starts from an empty SDK store, so every login is a new device with new
            // keys. An identity left over from the previous one would be an identity this device
            // cannot prove it owns, and the app would open on "verify this device" every time.
            deviceKeys = nil
            crossSigning = [:]
            oneTimeKeys = 0
            backup = nil
            for type in globalAccountData.keys
            where type.hasPrefix("m.secret_storage") || type.hasPrefix("m.cross_signing") || type.hasPrefix("m.megolm_backup") {
                globalAccountData[type] = nil
            }
            touchAccountData()
            return Self.ok(["user_id": me, "access_token": "demo-access-token",
                            "device_id": deviceID, "home_server": Self.serverName])
        case ("POST", "logout"):
            return Self.ok([:])
        case ("GET", "account") where segments.count > 1 && segments[1] == "whoami":
            return Self.ok(["user_id": me, "device_id": deviceID])
        case ("GET", "account") where segments.count > 1 && segments[1] == "3pid":
            return Self.ok(["threepids": []])
        case ("GET", "capabilities"):
            return Self.ok(["capabilities": ["m.change_password": ["enabled": false],
                                             "m.set_displayname": ["enabled": true],
                                             "m.set_avatar_url": ["enabled": true]]])
        case (_, "org.matrix.simplified_msc3575") where segments.last == "sync":
            if holdsSync { try await Task.sleep(for: .seconds(600)) }
            return try await slidingSync(query, body)
        case (_, "sync"):
            return try await slidingSync(query, body)
        case (_, "rooms") where segments.count >= 3:
            return try await roomRoute(method, segments[1], Array(segments.dropFirst(2)), query, body)
        case ("POST", "join"), ("POST", "knock"):
            guard segments.count > 1 else { break }
            return try join(segments[1])
        case ("POST", "createRoom"):
            return try createRoom(body)
        case ("GET", "joined_rooms"):
            return Self.ok(["joined_rooms": rooms.keys.filter { membership(of: me, in: $0) == "join" }])
        case (_, "profile") where segments.count > 1:
            return try profileRoute(method, segments, body)
        case (_, "user") where segments.count > 2:
            return try userRoute(method, Array(segments.dropFirst(2)), body)
        case ("POST", "user_directory"):
            return searchDirectory(body)
        case (_, "publicRooms"):
            return publicRooms()
        case (_, "directory"):
            return directory(method, Array(segments.dropFirst()), body)
        case (_, "pushrules"):
            return try pushRules(method, Array(segments.dropFirst()), body)
        case ("GET", "pushers"):
            return Self.ok(["pushers": []])
        case ("POST", "pushers"):
            return Self.ok([:])
        case (_, "presence"):
            return Self.ok(["presence": "online"])
        case ("GET", "devices") where segments.count == 1:
            return Self.ok(["devices": [deviceDescription()] + otherDevices])
        case ("GET", "devices"):
            return Self.ok(deviceDescription())
        case ("DELETE", "devices") where segments.count == 2:
            otherDevices.removeAll { $0["device_id"] as? String == segments[1] }
            return Self.ok([:])
        case ("POST", "delete_devices"):
            let ended = Set(body["devices"] as? [String] ?? [])
            otherDevices.removeAll { ended.contains($0["device_id"] as? String ?? "") }
            return Self.ok([:])
        case ("PUT", "devices"), ("DELETE", "devices"):
            return Self.ok([:])
        case (_, "keys"):
            return try keysRoute(method, Array(segments.dropFirst()), body)
        case (_, "room_keys"):
            return try roomKeysRoute(method, Array(segments.dropFirst()), query, body)
        case ("PUT", "sendToDevice"):
            return Self.ok([:])
        case ("GET", "thirdparty"):
            return Self.ok([:])
        case ("GET", "voip"):
            return Self.ok([:])
        default:
            break
        }
        return nil
    }

    // MARK: - Sliding sync

    private func slidingSync(_ query: [String: String], _ body: JSON) async throws -> ProxiedResponse {
        let position = query["pos"].flatMap(Int.init)
        let since = position.flatMap { positions[$0] } ?? Snapshot()
        let isFirst = position.map { positions[$0] == nil } ?? true
        let timeout = query["timeout"].flatMap(Int.init).map { min($0, 30_000) } ?? (isFirst ? 0 : 5_000)
        let limit = Self.timelineLimit(in: body)

        let deadline = ContinuousClock.now + .milliseconds(timeout)
        var (response, snapshot, changed) = syncDelta(since: since, limit: limit)
        while !changed && !isFirst && ContinuousClock.now < deadline {
            let seen = revision
            while revision == seen && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(100))
            }
            (response, snapshot, changed) = syncDelta(since: since, limit: limit)
        }

        let pos = nextPosition
        nextPosition += 1
        positions[pos] = snapshot
        positions = positions.filter { $0.key > pos - 64 }

        response["pos"] = String(pos)
        if let txn = body["txn_id"] { response["txn_id"] = txn }
        let visible = rooms.values.filter { ["join", "invite"].contains(membership(of: me, in: $0.id)) }.count
        var lists: JSON = [:]
        for name in ((body["lists"] as? JSON) ?? [:]).keys {
            lists[name] = ["count": visible]
        }
        response["lists"] = lists
        return Self.ok(response)
    }

    /// The biggest timeline anything in the request asked for, and never less than ten: a room
    /// arriving with one event and a history token is correct, and it is also a chat that opens
    /// on a spinner while the first page is fetched. The demo is for looking at screens.
    private static func timelineLimit(in body: JSON) -> Int {
        var limits: [Int] = []
        for case let list as JSON in ((body["lists"] as? JSON) ?? [:]).values {
            if let limit = list["timeline_limit"] as? Int { limits.append(limit) }
        }
        for case let sub as JSON in ((body["room_subscriptions"] as? JSON) ?? [:]).values {
            if let limit = sub["timeline_limit"] as? Int { limits.append(limit) }
        }
        return min(50, max(10, limits.max() ?? 10))
    }

    /// The rooms to send, the state they leave the connection in, and whether anything moved.
    private func syncDelta(since: Snapshot, limit: Int) -> (JSON, Snapshot, Bool) { // swiftlint:disable:this large_tuple
        var snapshot = since
        var roomsOut: JSON = [:]
        var roomData: JSON = [:]
        var receipts: JSON = [:]
        var typing: JSON = [:]

        for room in rooms.values {
            let membership = membership(of: me, in: room.id)
            var entry: JSON?

            switch membership {
            case "invite" where !since.invited.contains(room.id):
                entry = invitation(room)
                snapshot.invited.insert(room.id)
            case "join" where !since.joined.contains(room.id):
                entry = initialRoom(room, limit: limit)
                snapshot.joined.insert(room.id)
                snapshot.invited.remove(room.id)
            case "join", "leave", "ban":
                guard since.joined.contains(room.id) || since.invited.contains(room.id),
                      room.revision > since.revisions[room.id] ?? -1 else { break }
                entry = updatedRoom(room, from: since.delivered[room.id] ?? room.events.count)
                if membership != "join" {
                    snapshot.joined.remove(room.id)
                    snapshot.invited.remove(room.id)
                }
            default:
                break
            }

            guard let entry else { continue }
            roomsOut[room.id] = entry
            snapshot.delivered[room.id] = room.events.count
            snapshot.revisions[room.id] = room.revision
            if !room.accountData.isEmpty {
                roomData[room.id] = room.accountData.map { ["type": $0.key, "content": $0.value] }
            }
            receipts[room.id] = receiptEvent(room)
            typing[room.id] = ["type": "m.typing", "content": ["user_ids": Array(room.typing)]]
        }

        var extensions: JSON = [
            "to_device": ["next_batch": "0", "events": []],
            "e2ee": ["device_one_time_keys_count": ["signed_curve25519": oneTimeKeys],
                     "device_unused_fallback_key_types": ["signed_curve25519"],
                     "device_lists": ["changed": [], "left": []]],
            "receipts": ["rooms": receipts],
            "typing": ["rooms": typing],
        ]
        var accountData: JSON = ["rooms": roomData]
        let accountDataChanged = since.accountData < accountDataRevision
        if accountDataChanged {
            accountData["global"] = globalAccountData.map { ["type": $0.key, "content": $0.value] }
            snapshot.accountData = accountDataRevision
        }
        extensions["account_data"] = accountData

        let changed = !roomsOut.isEmpty || accountDataChanged
        return (["rooms": roomsOut, "extensions": extensions], snapshot, changed)
    }

    private func initialRoom(_ room: Room, limit: Int) -> JSON {
        let start = max(0, room.events.count - limit)
        var entry = summary(room)
        entry["initial"] = true
        entry["required_state"] = Array(room.state.values)
        entry["timeline"] = Array(room.events[start...])
        entry["limited"] = start > 0
        entry["prev_batch"] = "t\(start)"
        entry["num_live"] = 0
        return entry
    }

    private func updatedRoom(_ room: Room, from delivered: Int) -> JSON {
        var entry = summary(room)
        let fresh = Array(room.events[min(delivered, room.events.count)...])
        entry["timeline"] = fresh
        entry["limited"] = false
        entry["num_live"] = room.events.count - delivered
        // State that changed since the last answer, as a real server sends it: simplified sliding
        // sync carries room state in `required_state`, and the SDK reads it from there, not from the
        // timeline — with this empty, a change to the room's power levels was stored here and never
        // reached the client, and the rules screen put the old answer back.
        let changed = Set(fresh.compactMap { $0["state_key"] != nil ? $0["event_id"] as? String : nil })
        entry["required_state"] = room.state.values.filter { changed.contains($0["event_id"] as? String ?? "") }
        return entry
    }

    private func invitation(_ room: Room) -> JSON {
        let wanted = ["m.room.create", "m.room.name", "m.room.avatar", "m.room.topic",
                      "m.room.join_rules", "m.room.canonical_alias"]
        var stripped = room.state.values
            .filter { wanted.contains($0["type"] as? String ?? "") }
            .map { ["type": $0["type"] ?? NSNull(), "state_key": $0["state_key"] ?? NSNull(), "content": $0["content"] ?? NSNull(),
                    "sender": $0["sender"] ?? NSNull()] as JSON }
        if let own = room.state["m.room.member\u{0}\(me)"] {
            stripped.append(own)
        }
        var entry: JSON = ["initial": true, "invite_state": stripped, "timeline": [],
                           "bump_stamp": bumpStamp(room)]
        if let name = (room.state["m.room.name\u{0}"]?["content"] as? JSON)?["name"] {
            entry["name"] = name
        }
        return entry
    }

    private func summary(_ room: Room) -> JSON {
        let members = room.state.values.filter { $0["type"] as? String == "m.room.member" }
        let joined = members.filter { ($0["content"] as? JSON)?["membership"] as? String == "join" }
        let invited = members.filter { ($0["content"] as? JSON)?["membership"] as? String == "invite" }
        let heroes = members
            .filter { $0["state_key"] as? String != me }
            .filter { ["join", "invite"].contains(($0["content"] as? JSON)?["membership"] as? String ?? "") }
            .prefix(5)
            .map { event -> JSON in
                let content = event["content"] as? JSON ?? [:]
                var hero: JSON = ["user_id": event["state_key"] ?? ""]
                if let name = content["displayname"] { hero["displayname"] = name }
                if let avatar = content["avatar_url"] { hero["avatar_url"] = avatar }
                return hero
            }
        let (notifications, highlights) = unreadCounts(room)

        var entry: JSON = ["joined_count": joined.count, "invited_count": invited.count,
                           "notification_count": notifications, "highlight_count": highlights,
                           "heroes": Array(heroes), "bump_stamp": bumpStamp(room)]
        if let name = (room.state["m.room.name\u{0}"]?["content"] as? JSON)?["name"] {
            entry["name"] = name
        }
        if let avatar = (room.state["m.room.avatar\u{0}"]?["content"] as? JSON)?["url"] {
            entry["avatar"] = avatar
        }
        return entry
    }

    private func bumpStamp(_ room: Room) -> Int {
        let bumping: Set<String> = ["m.room.message", "m.room.create", "m.room.encrypted", "m.sticker",
                                    "org.matrix.msc3381.poll.start"]
        let last = room.events.last { bumping.contains($0["type"] as? String ?? "") }
        return last?["origin_server_ts"] as? Int ?? 0
    }

    /// Messages from other people after the last one this account has read.
    private func unreadCounts(_ room: Room) -> (Int, Int) {
        let readIndex = room.receipts[me].flatMap { receipt in
            room.events.firstIndex { $0["event_id"] as? String == receipt.eventID }
        } ?? -1
        var notifications = 0
        var highlights = 0
        for event in room.events.dropFirst(readIndex + 1)
        where event["sender"] as? String != me && event["type"] as? String == "m.room.message" {
            notifications += 1
            let mentions = ((event["content"] as? JSON)?["m.mentions"] as? JSON)?["user_ids"] as? [String]
            if mentions?.contains(me) == true { highlights += 1 }
        }
        return (notifications, highlights)
    }

    private func receiptEvent(_ room: Room) -> JSON {
        var content: JSON = [:]
        for (user, receipt) in room.receipts {
            var byType = content[receipt.eventID] as? JSON ?? [:]
            var users = byType["m.read"] as? JSON ?? [:]
            users[user] = ["ts": receipt.ts]
            byType["m.read"] = users
            content[receipt.eventID] = byType
        }
        return ["type": "m.receipt", "content": content]
    }

    // MARK: - Changing the world

    func membership(of user: String, in roomID: String) -> String? {
        (rooms[roomID]?.state["m.room.member\u{0}\(user)"]?["content"] as? JSON)?["membership"] as? String
    }

    /// Adds an event to a room, as the server would: an ID, a timestamp, and — for state — the
    /// new state. Everything a sync is waiting for is woken by this.
    @discardableResult
    func append(_ roomID: String, sender: String, type: String, content: JSON,
                stateKey: String? = nil, transactionID: String? = nil, extra: JSON = [:]) -> String {
        let eventID = "$" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(24).lowercased()
        var event: JSON = ["event_id": eventID, "type": type, "sender": sender, "room_id": roomID,
                           "origin_server_ts": Int(Date().timeIntervalSince1970 * 1000),
                           "content": content, "unsigned": transactionID.map { ["transaction_id": $0] } ?? [:]]
        if let stateKey { event["state_key"] = stateKey }
        for (key, value) in extra { event[key] = value }

        rooms[roomID]?.events.append(event)
        if let stateKey { rooms[roomID]?.state["\(type)\u{0}\(stateKey)"] = event }
        // Your own message is one you have read.
        if sender == me { rooms[roomID]?.receipts[me] = (eventID, event["origin_server_ts"] as? Int ?? 0) }
        touch(roomID)
        return eventID
    }

    func touch(_ roomID: String) {
        rooms[roomID]?.revision += 1
        revision += 1
    }

    func touchAccountData() {
        accountDataRevision += 1
        revision += 1
    }

    private func sendMessage(_ roomID: String, type: String, txn: String, content: JSON) -> JSON {
        let key = "\(roomID)/\(txn)"
        if let existing = sentTransactions[key] { return ["event_id": existing] }
        let eventID = append(roomID, sender: me, type: type, content: content, transactionID: txn)
        sentTransactions[key] = eventID
        if type == "m.room.message" || type == "m.room.encrypted" { scheduleReply(in: roomID, to: eventID) }
        return ["event_id": eventID]
    }

    /// Somebody answers. Not cleverly — the point is to watch "typing…" come and go, a receipt move
    /// onto your message, and a new one land, which are three screens' worth of behaviour nobody
    /// can see in a chat where nobody else is.
    private func scheduleReply(in roomID: String, to eventID: String) {
        guard let room = rooms[roomID] else { return }
        let others = room.state.values
            .filter { $0["type"] as? String == "m.room.member" && $0["state_key"] as? String != me }
            .filter { ["join", "invite"].contains(($0["content"] as? JSON)?["membership"] as? String ?? "") }
            .compactMap { $0["state_key"] as? String }
        guard let responder = others.randomElement() else { return }
        let delay = replyDelay

        Task {
            try? await Task.sleep(for: .milliseconds(800))
            // Written to before they had accepted: they accept first, as anybody would.
            self.joinAs(responder, roomID)
            self.read(roomID, by: responder, upTo: eventID)
            self.setTyping(roomID, responder, true)
            try? await Task.sleep(for: delay)
            self.setTyping(roomID, responder, false)
            self.append(roomID, sender: responder, type: "m.room.message",
                              content: ["msgtype": "m.text", "body": MockWorld.replies.randomElement() ?? "🙂"])
        }
    }

    func read(_ roomID: String, by user: String, upTo eventID: String) {
        rooms[roomID]?.receipts[user] = (eventID, Int(Date().timeIntervalSince1970 * 1000))
        touch(roomID)
    }

    private func setTyping(_ roomID: String, _ user: String, _ typing: Bool) {
        if typing { rooms[roomID]?.typing.insert(user) } else { rooms[roomID]?.typing.remove(user) }
        touch(roomID)
    }

    /// A person the app invited turns up a moment later, as people in a demo do.
    private func acceptLater(_ user: String, in roomID: String) {
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            self.joinAs(user, roomID)
        }
    }

    private func joinAs(_ user: String, _ roomID: String) {
        guard membership(of: user, in: roomID) == "invite" else { return }
        var content = memberContent(user)
        content["membership"] = "join"
        append(roomID, sender: user, type: "m.room.member", content: content, stateKey: user)
    }

    func memberContent(_ user: String) -> JSON {
        var content: JSON = ["membership": "join"]
        if let profile = profiles[user] {
            content["displayname"] = profile.name
            if let avatar = profile.avatar { content["avatar_url"] = avatar }
        }
        return content
    }

    // MARK: - Rooms

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private func roomRoute(_ method: String, _ roomID: String, _ segments: [String], _ query: [String: String],
                           _ body: JSON) async throws -> ProxiedResponse? {
        let action = segments[0]
        if action == "join", method == "POST" { return try join(roomID) }
        if action == "hierarchy" { return try hierarchy(roomID) }
        guard let room = rooms[roomID] else { throw Failure(404, "M_NOT_FOUND", "Unknown room") }

        switch (method, action) {
        case ("PUT", "send") where segments.count >= 3:
            return Self.ok(sendMessage(roomID, type: segments[1], txn: segments[2], content: body))

        case ("PUT", "redact") where segments.count >= 3:
            let key = "\(roomID)/\(segments[2])"
            if let existing = sentTransactions[key] { return Self.ok(["event_id": existing]) }
            var content: JSON = ["redacts": segments[1]]
            if let reason = body["reason"] { content["reason"] = reason }
            redactInPlace(roomID, segments[1])
            let id = append(roomID, sender: me, type: "m.room.redaction", content: content,
                            transactionID: segments[2], extra: ["redacts": segments[1]])
            sentTransactions[key] = id
            return Self.ok(["event_id": id])

        case ("PUT", "state") where segments.count >= 2:
            let stateKey = segments.count > 2 ? segments[2] : ""
            return Self.ok(["event_id": append(roomID, sender: me, type: segments[1], content: body, stateKey: stateKey)])

        case ("GET", "state") where segments.count == 1:
            return Self.okArray(Array(room.state.values))

        case ("GET", "state"):
            let stateKey = segments.count > 2 ? segments[2] : ""
            guard let event = room.state["\(segments[1])\u{0}\(stateKey)"] else {
                throw Failure(404, "M_NOT_FOUND", "Event not found")
            }
            return Self.ok(event["content"] as? JSON ?? [:])

        case ("GET", "members"):
            let excluded = query["not_membership"]
            let members = room.state.values.filter {
                $0["type"] as? String == "m.room.member"
                    && (excluded == nil || ($0["content"] as? JSON)?["membership"] as? String != excluded)
            }
            return Self.ok(["chunk": members])

        case ("GET", "joined_members"):
            var joined: JSON = [:]
            for event in room.state.values where event["type"] as? String == "m.room.member" {
                let content = event["content"] as? JSON ?? [:]
                guard content["membership"] as? String == "join", let user = event["state_key"] as? String else { continue }
                joined[user] = ["display_name": content["displayname"] ?? NSNull(),
                                "avatar_url": content["avatar_url"] ?? NSNull()]
            }
            return Self.ok(["joined": joined])

        case ("GET", "messages"):
            return Self.ok(messages(roomID, query))

        case ("GET", "event") where segments.count > 1:
            guard let event = room.events.first(where: { $0["event_id"] as? String == segments[1] }) else {
                throw Failure(404, "M_NOT_FOUND", "Event not found")
            }
            return Self.ok(event)

        case ("GET", "context") where segments.count > 1:
            return Self.ok(try context(roomID, segments[1], limit: query["limit"].flatMap(Int.init) ?? 10))

        case ("GET", "relations") where segments.count > 1:
            let related = room.events.filter {
                (($0["content"] as? JSON)?["m.relates_to"] as? JSON)?["event_id"] as? String == segments[1]
                    && (segments.count < 3 || (($0["content"] as? JSON)?["m.relates_to"] as? JSON)?["rel_type"] as? String == segments[2])
            }
            return Self.ok(["chunk": Array(related.reversed())])

        case ("GET", "threads"):
            return Self.ok(["chunk": []])

        case ("POST", "receipt") where segments.count >= 3:
            read(roomID, by: me, upTo: segments[2])
            return Self.ok([:])

        case ("POST", "read_markers"):
            if let read = (body["m.read"] ?? body["m.read.private"]) as? String {
                rooms[roomID]?.receipts[me] = (read, Int(Date().timeIntervalSince1970 * 1000))
            }
            if let fully = body["m.fully_read"] as? String {
                rooms[roomID]?.accountData["m.fully_read"] = ["event_id": fully]
            }
            touch(roomID)
            return Self.ok([:])

        case ("PUT", "typing"):
            return Self.ok([:])

        case ("POST", "leave"):
            if membership(of: me, in: roomID) != "leave" {
                append(roomID, sender: me, type: "m.room.member", content: ["membership": "leave"], stateKey: me)
            }
            return Self.ok([:])

        case ("POST", "forget"):
            return Self.ok([:])

        case ("POST", "invite"):
            guard let user = body["user_id"] as? String else { throw Failure(400, "M_MISSING_PARAM") }
            invite(user, to: roomID)
            return Self.ok([:])

        case ("POST", "kick"), ("POST", "ban"), ("POST", "unban"):
            guard let user = body["user_id"] as? String else { throw Failure(400, "M_MISSING_PARAM") }
            var content: JSON = ["membership": action == "ban" ? "ban" : "leave"]
            if let reason = body["reason"] { content["reason"] = reason }
            append(roomID, sender: me, type: "m.room.member", content: content, stateKey: user)
            return Self.ok([:])

        case ("POST", "report"):
            return Self.ok([:])

        case ("GET", "aliases"):
            return Self.ok(["aliases": []])

        case ("GET", "timestamp_to_event"):
            let ts = query["ts"].flatMap(Int.init) ?? 0
            let events = room.events
            let hit = query["dir"] == "b"
                ? events.last { ($0["origin_server_ts"] as? Int ?? 0) <= ts }
                : events.first { ($0["origin_server_ts"] as? Int ?? 0) >= ts }
            guard let hit else { throw Failure(404, "M_NOT_FOUND") }
            return Self.ok(["event_id": hit["event_id"] ?? NSNull(), "origin_server_ts": hit["origin_server_ts"] ?? NSNull()])

        default:
            return nil
        }
    }

    /// History, older first in the token and newest first in the chunk, as `/messages` returns it.
    private func messages(_ roomID: String, _ query: [String: String]) -> JSON {
        guard let events = rooms[roomID]?.events else { return ["chunk": [], "state": []] }
        let limit = min(100, query["limit"].flatMap(Int.init) ?? 10)
        let from = query["from"].flatMap { Int($0.dropFirst()) } ?? events.count
        let clamped = max(0, min(from, events.count))

        if query["dir"] == "f" {
            let end = min(events.count, clamped + limit)
            return ["chunk": Array(events[clamped..<end]), "start": "t\(clamped)", "end": "t\(end)", "state": []]
        }

        let start = max(0, clamped - limit)
        var response: JSON = ["chunk": Array(events[start..<clamped].reversed()), "start": "t\(clamped)", "state": []]
        if start > 0 { response["end"] = "t\(start)" }
        return response
    }

    private func context(_ roomID: String, _ eventID: String, limit: Int) throws -> JSON {
        guard let room = rooms[roomID] else { throw Failure(404, "M_NOT_FOUND", "Unknown room") }
        let events = room.events
        guard let index = events.firstIndex(where: { $0["event_id"] as? String == eventID }) else {
            throw Failure(404, "M_NOT_FOUND", "Event not found")
        }
        let before = max(0, index - limit / 2)
        let after = min(events.count, index + 1 + limit / 2)
        return ["event": events[index],
                "events_before": Array(events[before..<index].reversed()),
                "events_after": Array(events[(index + 1)..<after]),
                "start": "t\(before)", "end": "t\(after)",
                "state": Array(room.state.values)]
    }

    private func redactInPlace(_ roomID: String, _ eventID: String) {
        guard let index = rooms[roomID]?.events.firstIndex(where: { $0["event_id"] as? String == eventID }) else { return }
        rooms[roomID]?.events[index]["content"] = [:] as JSON
        rooms[roomID]?.events[index]["unsigned"] = ["redacted_because": ["type": "m.room.redaction",
                                                                         "sender": me,
                                                                         "content": ["redacts": eventID]]]
    }

    private func invite(_ user: String, to roomID: String) {
        guard membership(of: user, in: roomID) != "join" else { return }
        var content = memberContent(user)
        content["membership"] = "invite"
        append(roomID, sender: me, type: "m.room.member", content: content, stateKey: user)
        acceptLater(user, in: roomID)
    }

    private func join(_ roomIDOrAlias: String) throws -> ProxiedResponse {
        guard rooms[roomIDOrAlias] != nil else { throw Failure(404, "M_NOT_FOUND", "No such room") }
        if membership(of: me, in: roomIDOrAlias) != "join" {
            append(roomIDOrAlias, sender: me, type: "m.room.member", content: memberContent(me), stateKey: me)
        }
        return Self.ok(["room_id": roomIDOrAlias])
    }

    private func createRoom(_ body: JSON) throws -> ProxiedResponse {
        let id = "!" + UUID().uuidString.prefix(12).lowercased() + ":" + Self.serverName
        rooms[id] = Room(id: id)
        var creation = body["creation_content"] as? JSON ?? [:]
        creation["room_version"] = "11"
        append(id, sender: me, type: "m.room.create", content: creation, stateKey: "")
        append(id, sender: me, type: "m.room.member", content: memberContent(me), stateKey: me)

        var power = MockWorld.powerLevels(admins: [me])
        if let override = body["power_level_content_override"] as? JSON {
            for (key, value) in override { power[key] = value }
        }
        append(id, sender: me, type: "m.room.power_levels", content: power, stateKey: "")

        let isPublic = (body["preset"] as? String) == "public_chat" || (body["visibility"] as? String) == "public"
        append(id, sender: me, type: "m.room.join_rules", content: ["join_rule": isPublic ? "public" : "invite"], stateKey: "")
        append(id, sender: me, type: "m.room.history_visibility", content: ["history_visibility": "shared"], stateKey: "")
        if let name = body["name"] as? String, !name.isEmpty {
            append(id, sender: me, type: "m.room.name", content: ["name": name], stateKey: "")
        }
        if let topic = body["topic"] as? String, !topic.isEmpty {
            append(id, sender: me, type: "m.room.topic", content: ["topic": topic], stateKey: "")
        }
        for case let state as JSON in body["initial_state"] as? [Any] ?? [] {
            guard let type = state["type"] as? String else { continue }
            append(id, sender: me, type: type, content: state["content"] as? JSON ?? [:],
                   stateKey: state["state_key"] as? String ?? "")
        }
        for case let user as String in body["invite"] as? [Any] ?? [] {
            var content = memberContent(user)
            content["membership"] = "invite"
            if body["is_direct"] as? Bool == true { content["is_direct"] = true }
            append(id, sender: me, type: "m.room.member", content: content, stateKey: user)
            acceptLater(user, in: id)
        }
        if isPublic { publicRoomIDs.append(id) }
        return Self.ok(["room_id": id])
    }

    private func hierarchy(_ spaceID: String) throws -> ProxiedResponse {
        guard let space = rooms[spaceID] else { throw Failure(404, "M_NOT_FOUND") }
        let children = space.state.values.filter { $0["type"] as? String == "m.space.child" }
        var chunk = [publishedRoom(space, children: children)]
        for child in children {
            if let id = child["state_key"] as? String, let room = rooms[id] {
                chunk.append(publishedRoom(room, children: []))
            }
        }
        return Self.ok(["rooms": chunk])
    }

    private func publishedRoom(_ room: Room, children: [JSON] = []) -> JSON {
        let state = { (type: String, key: String) in (room.state["\(type)\u{0}"]?["content"] as? JSON)?[key] }
        let joined = room.state.values.filter {
            $0["type"] as? String == "m.room.member" && ($0["content"] as? JSON)?["membership"] as? String == "join"
        }.count
        var entry: JSON = ["room_id": room.id, "num_joined_members": joined, "world_readable": false,
                           "guest_can_join": false,
                           "join_rule": state("m.room.join_rules", "join_rule") ?? "invite",
                           "children_state": children.map {
                               ["type": "m.space.child", "state_key": $0["state_key"] ?? NSNull(), "content": $0["content"] ?? NSNull(),
                                "sender": $0["sender"] ?? NSNull(), "origin_server_ts": $0["origin_server_ts"] ?? NSNull()] as JSON
                           }]
        if let name = state("m.room.name", "name") { entry["name"] = name }
        if let topic = state("m.room.topic", "topic") { entry["topic"] = topic }
        if let avatar = state("m.room.avatar", "url") { entry["avatar_url"] = avatar }
        if let type = state("m.room.create", "type") { entry["room_type"] = type }
        return entry
    }

    private func publicRooms() -> ProxiedResponse {
        let chunk = publicRoomIDs.compactMap { rooms[$0] }.map { publishedRoom($0) }
        return Self.ok(["chunk": chunk, "total_room_count_estimate": chunk.count])
    }

    private func searchDirectory(_ body: JSON) -> ProxiedResponse {
        let term = (body["search_term"] as? String ?? "").lowercased()
        let results = profiles
            .filter { $0.key != me }
            .filter { term.isEmpty || $0.key.lowercased().contains(term) || $0.value.name.lowercased().contains(term) }
            .sorted { $0.value.name < $1.value.name }
            .map { user, profile -> JSON in
                var result: JSON = ["user_id": user, "display_name": profile.name]
                if let avatar = profile.avatar { result["avatar_url"] = avatar }
                return result
            }
        return Self.ok(["results": results, "limited": false])
    }

    // MARK: - Profiles and account data

    private func profileRoute(_ method: String, _ segments: [String], _ body: JSON) throws -> ProxiedResponse {
        let user = segments[1]
        guard var profile = profiles[user] else { throw Failure(404, "M_NOT_FOUND", "Profile not found") }

        if method == "PUT", segments.count > 2, user == me {
            if segments[2] == "displayname" { profile.name = body["displayname"] as? String ?? profile.name }
            if segments[2] == "avatar_url" { profile.avatar = (body["avatar_url"] as? String).flatMap { $0.isEmpty ? nil : $0 } }
            profiles[user] = profile
            // A new name is news in every room you are in, as it is on a real server.
            for id in rooms.keys where membership(of: me, in: id) == "join" {
                append(id, sender: me, type: "m.room.member", content: memberContent(me), stateKey: me)
            }
            return Self.ok([:])
        }

        var answer: JSON = [:]
        if segments.count < 3 || segments[2] == "displayname" { answer["displayname"] = profile.name }
        if segments.count < 3 || segments[2] == "avatar_url", let avatar = profile.avatar { answer["avatar_url"] = avatar }
        return Self.ok(answer)
    }

    /// `/user/{me}/…`: account data, room account data, tags and filters.
    private func userRoute(_ method: String, _ segments: [String], _ body: JSON) throws -> ProxiedResponse? {
        switch (method, segments.first ?? "") {
        case ("POST", "filter"):
            return Self.ok(["filter_id": "1"])
        case ("GET", "account_data") where segments.count > 1:
            guard let content = globalAccountData[segments[1]] else { throw Failure(404, "M_NOT_FOUND", "Account data not found") }
            return Self.ok(content)
        case ("PUT", "account_data") where segments.count > 1:
            globalAccountData[segments[1]] = body
            touchAccountData()
            return Self.ok([:])
        case (_, "rooms") where segments.count >= 3:
            let roomID = segments[1]
            guard let room = rooms[roomID] else { throw Failure(404, "M_NOT_FOUND") }
            if segments[2] == "tags" {
                var tags = (room.accountData["m.tag"]?["tags"] as? JSON) ?? [:]
                switch method {
                case "GET": return Self.ok(["tags": tags])
                case "PUT" where segments.count > 3: tags[segments[3]] = body
                case "DELETE" where segments.count > 3: tags[segments[3]] = nil
                default: break
                }
                rooms[roomID]?.accountData["m.tag"] = ["tags": tags]
                touch(roomID)
                return Self.ok([:])
            }
            if segments[2] == "account_data", segments.count > 3 {
                if method == "PUT" {
                    rooms[roomID]?.accountData[segments[3]] = body
                    touch(roomID)
                    return Self.ok([:])
                }
                guard let content = room.accountData[segments[3]] else { throw Failure(404, "M_NOT_FOUND") }
                return Self.ok(content)
            }
            return nil
        case ("POST", "openid"):
            return Self.ok(["access_token": "demo", "token_type": "Bearer",
                            "matrix_server_name": Self.serverName, "expires_in": 3600])
        default:
            return nil
        }
    }

    /// Push rules live in account data, as they do on a real server, so a change made here
    /// arrives back through sync — which is where the SDK's notification settings read them.
    private func pushRules(_ method: String, _ segments: [String], _ body: JSON) throws -> ProxiedResponse {
        var rules = globalAccountData["m.push_rules"] ?? MockWorld.pushRules(for: me)
        guard segments.count >= 3 else { return Self.ok(rules) }
        let kind = segments[1]
        let ruleID = segments[2]
        var global = rules["global"] as? JSON ?? [:]
        var list = global[kind] as? [JSON] ?? []
        let index = list.firstIndex { $0["rule_id"] as? String == ruleID }

        switch method {
        case "GET":
            guard let index else { throw Failure(404, "M_NOT_FOUND") }
            if segments.count > 3 { return Self.ok([segments[3]: list[index][segments[3]] ?? NSNull()]) }
            return Self.ok(list[index])
        case "DELETE":
            if let index { list.remove(at: index) }
        case "PUT" where segments.count > 3:
            guard let index else { throw Failure(404, "M_NOT_FOUND") }
            list[index][segments[3]] = body[segments[3]]
        case "PUT":
            var rule = body
            rule["rule_id"] = ruleID
            rule["default"] = false
            rule["enabled"] = true
            if kind == "room" || kind == "sender" { rule["conditions"] = nil }
            if let index { list[index] = rule } else { list.insert(rule, at: 0) }
        default:
            break
        }
        global[kind] = list
        rules["global"] = global
        globalAccountData["m.push_rules"] = rules
        touchAccountData()
        return Self.ok([:])
    }

    private func deviceDescription() -> JSON {
        ["device_id": deviceID, "display_name": "Iskra (демо)",
         "last_seen_ts": Int(Date().timeIntervalSince1970 * 1000), "last_seen_ip": "127.0.0.1"]
    }

    // MARK: - Keys

    private func keysRoute(_ method: String, _ segments: [String], _ body: JSON) throws -> ProxiedResponse? {
        switch segments.first ?? "" {
        case "upload":
            if let keys = body["device_keys"] as? JSON { deviceKeys = keys }
            oneTimeKeys += (body["one_time_keys"] as? JSON)?.count ?? 0
            return Self.ok(["one_time_key_counts": ["signed_curve25519": oneTimeKeys]])

        case "query":
            let asked = (body["device_keys"] as? JSON)?.keys.map { $0 } ?? []
            var devices: JSON = [:]
            for user in asked {
                devices[user] = user == me ? (deviceKeys.map { [deviceID: $0] } ?? [:]) : [:] as JSON
            }
            var answer: JSON = ["device_keys": devices, "failures": [:]]
            if asked.contains(me) {
                for (kind, field) in [("master", "master_keys"), ("self_signing", "self_signing_keys"),
                                      ("user_signing", "user_signing_keys")] {
                    if let key = crossSigning[kind] { answer[field] = [me: key] }
                }
            }
            return Self.ok(answer)

        case "claim":
            return Self.ok(["one_time_keys": [:], "failures": [:]])

        case "changes":
            return Self.ok(["changed": [], "left": []])

        case "device_signing":
            for kind in ["master", "self_signing", "user_signing"] {
                if let key = body["\(kind)_key"] as? JSON { crossSigning[kind] = key }
            }
            return Self.ok([:])

        case "signatures":
            for case let (keyID, signed as JSON) in (body[me] as? JSON) ?? [:] {
                if keyID == deviceID, let existing = deviceKeys {
                    deviceKeys = Self.mergeSignatures(existing, signed)
                // "master" is the Matrix spec's name for the cross-signing root key.
                // swiftlint:disable:next inclusive_language
                } else if let master = crossSigning["master"],
                          (master["keys"] as? JSON)?.keys.contains("ed25519:\(keyID)") == true {
                    crossSigning["master"] = Self.mergeSignatures(master, signed)
                }
            }
            return Self.ok(["failures": [:]])

        default:
            return nil
        }
    }

    private static func mergeSignatures(_ target: JSON, _ source: JSON) -> JSON {
        var target = target
        var all = target["signatures"] as? JSON ?? [:]
        for case let (user, signatures as JSON) in source["signatures"] as? JSON ?? [:] {
            var existing = all[user] as? JSON ?? [:]
            for (key, value) in signatures { existing[key] = value }
            all[user] = existing
        }
        target["signatures"] = all
        return target
    }

    private func roomKeysRoute(_ method: String, _ segments: [String], _ query: [String: String],
                               _ body: JSON) throws -> ProxiedResponse? {
        switch (method, segments.first ?? "") {
        case ("GET", "version"):
            guard var backup else { throw Failure(404, "M_NOT_FOUND", "No current backup version") }
            backup["count"] = backupKeys
            backup["etag"] = String(backupKeys)
            return Self.ok(backup)
        case ("POST", "version"):
            let version = String((Int(backup?["version"] as? String ?? "0") ?? 0) + 1)
            backup = ["algorithm": body["algorithm"] ?? "", "auth_data": body["auth_data"] ?? [:], "version": version]
            backupKeys = 0
            return Self.ok(["version": version])
        case ("PUT", "version"):
            backup?["auth_data"] = body["auth_data"]
            return Self.ok([:])
        case ("DELETE", "version"):
            backup = nil
            return Self.ok([:])
        case ("PUT", "keys"):
            for case let room as JSON in ((body["rooms"] as? JSON) ?? [:]).values {
                backupKeys += (room["sessions"] as? JSON)?.count ?? 0
            }
            return Self.ok(["count": backupKeys, "etag": String(backupKeys)])
        case ("GET", "keys"):
            return Self.ok(["rooms": [:]])
        default:
            return nil
        }
    }

    // MARK: - Media

    private func mediaRoute(_ method: String, _ segments: [String], _ query: [String: String],
                            _ raw: ProxiedRequest) throws -> ProxiedResponse? {
        switch (method, segments.first ?? "") {
        case ("GET", "config"):
            return Self.ok(["m.upload.size": 100 * 1024 * 1024])
        case ("POST", "upload"):
            let id = UUID().uuidString.lowercased()
            let mime = raw.headers.first { $0.key.lowercased() == "content-type" }?.value ?? "application/octet-stream"
            media[id] = (raw.body, mime)
            return Self.ok(["content_uri": "mxc://\(Self.serverName)/\(id)"])
        case ("GET", "download"), ("GET", "thumbnail"):
            guard segments.count >= 3, let file = media[segments[2]] else { throw Failure(404, "M_NOT_FOUND", "Not found") }
            return ProxiedResponse(status: 200, headers: ["Content-Type": file.mime], body: file.data)
        case ("GET", "preview_url"):
            return Self.ok([:])
        default:
            return nil
        }
    }

    // MARK: - Plumbing

    static var versions: JSON { [
        "versions": ["r0.6.1", "v1.1", "v1.2", "v1.3", "v1.4", "v1.5", "v1.6", "v1.7", "v1.8", "v1.9",
                     "v1.10", "v1.11", "v1.12"],
        "unstable_features": ["org.matrix.simplified_msc3575": true, "org.matrix.msc3916.stable": true],
    ] }

    static func split(_ target: String) -> ([String], [String: String]) {
        let parts = target.split(separator: "?", maxSplits: 1)
        let path = (parts.first ?? "").split(separator: "/", omittingEmptySubsequences: false)
            .dropFirst()
            .map { String($0).removingPercentEncoding ?? String($0) }
        var query: [String: String] = [:]
        if parts.count > 1 {
            for pair in parts[1].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                let key = String(kv[0]).removingPercentEncoding ?? String(kv[0])
                query[key] = kv.count > 1 ? (String(kv[1]).removingPercentEncoding ?? String(kv[1])) : ""
            }
        }
        // A trailing slash is an empty last segment. Dropped: where it means something — the empty
        // state key in `state/m.room.name/` — a missing key already reads as the empty one.
        return (path.last?.isEmpty == true ? Array(path.dropLast()) : Array(path), query)
    }

    static func ok(_ body: JSON) -> ProxiedResponse {
        ProxiedResponse(status: 200, headers: ["Content-Type": "application/json"],
                        body: (try? JSONSerialization.data(withJSONObject: body)) ?? Data("{}".utf8))
    }

    static func okArray(_ body: [JSON]) -> ProxiedResponse {
        ProxiedResponse(status: 200, headers: ["Content-Type": "application/json"],
                        body: (try? JSONSerialization.data(withJSONObject: body)) ?? Data("[]".utf8))
    }

    static func error(_ status: Int, _ code: String, _ message: String = "") -> ProxiedResponse {
        ProxiedResponse(status: status, headers: ["Content-Type": "application/json"],
                        body: (try? JSONSerialization.data(withJSONObject: ["errcode": code, "error": message]))
                            ?? Data())
    }
}
