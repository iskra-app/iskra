import Foundation
import MatrixRustSDK

/// Somebody the homeserver's user directory knows about — a row in "New chat" that is not yet a
/// conversation.
public struct PersonProfile: Sendable, Identifiable, Hashable {
    /// The Matrix ID. Also what their generated face is computed from.
    public let id: String
    public let displayName: String?
    public let avatarURL: String?

    public init(id: String, displayName: String?, avatarURL: String?) {
        self.id = id
        self.displayName = displayName
        self.avatarURL = avatarURL
    }

    /// What to call them: the name they gave themselves, or their address if they gave none.
    public var name: String {
        guard let displayName, !displayName.trimmingCharacters(in: .whitespaces).isEmpty else { return id }
        return displayName
    }
}

/// A room listed in a homeserver's public directory.
public struct PublicRoom: Sendable, Identifiable, Hashable {
    public let id: String
    public let name: String?
    public let topic: String?
    /// `#name:server`, when the room has one. It is what a person would type to find it again.
    public let alias: String?
    public let avatarURL: String?
    public let memberCount: Int
    /// Anybody may walk in. The rest of the directory is rooms that list themselves and then ask
    /// to be knocked on, or invited into — shown, because they are there, but not joinable with
    /// a tap, and the row says so instead of failing on it.
    public let isOpen: Bool

    /// The room's name, its address, or its ID — in that order, because a directory row with
    /// nothing written on it is not a row anybody would tap.
    public var title: String {
        if let name, !name.isEmpty { return name }
        return alias ?? id
    }

    init(_ preview: RoomPreviewInfo) {
        id = preview.roomId
        name = preview.name
        topic = preview.topic?.trimmingCharacters(in: .whitespacesAndNewlines)
        alias = preview.canonicalAlias
        avatarURL = preview.avatarUrl
        memberCount = Int(preview.numJoinedMembers)
        isOpen = preview.joinRule == nil || preview.joinRule == .public
    }

    init(_ description: RoomDescription) {
        id = description.roomId
        name = description.name
        topic = description.topic?.trimmingCharacters(in: .whitespacesAndNewlines)
        alias = description.alias
        avatarURL = description.avatarUrl
        memberCount = Int(description.joinedMembers)
        // No join rule at all is how older servers list an open room.
        isOpen = description.joinRule == nil || description.joinRule == .public
    }
}

/// A room that would not be joined. As with creating one, a typo is a different failure from a
/// refusal, and the person can fix only one of them.
public enum RoomJoinFailure: String, CaseIterable, ActionFailure, Error {
    /// Not `#alias:server` and not `!id:server`.
    case badAddress
    /// No such room, a room that is not open, or a server that did not answer.
    case refused

    public var id: String { rawValue }

    public var explanation: LocalizedStringResource {
        switch self {
        case .badAddress: CoreStrings.RoomAction.joinAddressInvalid
        case .refused: CoreStrings.RoomAction.joinFailed
        }
    }
}

public extension UserSession {
    /// Asks the homeserver's user directory who answers to `term`.
    ///
    /// The directory is the server's, and what it covers is the server's decision too: by default
    /// a homeserver lists only people who share a room with you or are in a public one. An exact
    /// Matrix ID that the directory does not know is still somebody you can write to — that row
    /// is the caller's to add, because only it knows what was typed.
    func searchPeople(_ term: String, limit: Int = 30) async throws -> [PersonProfile] {
        let trimmed = term.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }

        let client = self.client
        let ownID = userID
        let results = try await withTimeout(Self.directoryTimeout) {
            try await client.searchUsers(searchTerm: trimmed, limit: UInt64(limit))
        }
        return results.results
            .filter { $0.userId != ownID }
            .map { PersonProfile(id: $0.userId, displayName: $0.displayName, avatarURL: $0.avatarUrl) }
    }

    /// Joins a room by what somebody typed: `#name:server`, or `!id:server`.
    ///
    /// The server part of an alias is passed as the server to ask through. For an alias the SDK
    /// resolves it anyway; for a bare room ID it is the only hint there is, and without one a
    /// homeserver that is not already in the room has nobody to ask.
    func joinRoom(address: String) async throws(RoomJoinFailure) -> String {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isRoomAddress(trimmed) else { throw .badAddress }

        let via = trimmed.split(separator: ":", maxSplits: 1).dropFirst().first.map { [String($0)] } ?? []
        return try await join(trimmed, via: via)
    }

    /// Joins the room a link pointed at — see `MatrixLink`, which carries the servers to ask through.
    func joinRoom(_ idOrAlias: String, via servers: [String]) async throws(RoomJoinFailure) -> String {
        guard Self.isRoomAddress(idOrAlias) else { throw .badAddress }
        return try await join(idOrAlias, via: servers)
    }

    /// The room this account is already in by that ID or alias, if it is in one. Local, so a QR
    /// code for a room you are in opens it at once, offline included, rather than asking a server
    /// to let you into a room you never left.
    func joinedRoom(_ idOrAlias: String) async -> String? {
        if idOrAlias.hasPrefix("!") {
            guard let room = try? client.getRoom(roomId: idOrAlias), room.membership() == .joined else { return nil }
            return room.id()
        }
        let client = self.client
        guard let resolved = try? await withTimeout(Self.directoryTimeout, operation: {
            try await client.resolveRoomAlias(roomAlias: idOrAlias)
        }) as ResolvedRoomAlias??, let resolved,
              let room = try? client.getRoom(roomId: resolved.roomId), room.membership() == .joined else { return nil }
        return room.id()
    }

    /// What a room a link points at is, before deciding to walk into it: name, topic, head count.
    /// Nil when the server will not say — a private room, or none at all; joining may still work,
    /// and the caller offers it anyway.
    func roomPreview(_ idOrAlias: String, via servers: [String]) async -> PublicRoom? {
        let client = self.client
        let preview = try? await withTimeout(Self.directoryTimeout) {
            if idOrAlias.hasPrefix("#") {
                try await client.getRoomPreviewFromRoomAlias(roomAlias: idOrAlias)
            } else {
                try await client.getRoomPreviewFromRoomId(roomId: idOrAlias, viaServers: servers)
            }
        }
        return preview.map { PublicRoom($0.info()) }
    }

    /// Whatever the homeserver will say about somebody: their name and picture. Somebody it cannot
    /// say anything about is still somebody — the ID alone comes back, and the caller can still
    /// write to them.
    func profile(of userID: String) async -> PersonProfile {
        let client = self.client
        guard let profile = try? await withTimeout(Self.directoryTimeout, operation: {
            try await client.getProfile(userId: userID)
        }) else {
            return PersonProfile(id: userID, displayName: nil, avatarURL: nil)
        }
        return PersonProfile(id: userID, displayName: profile.displayName, avatarURL: profile.avatarUrl)
    }

    /// Joins a room from the public directory.
    func joinRoom(_ room: PublicRoom) async throws(RoomJoinFailure) -> String {
        try await join(room.alias ?? room.id, via: [])
    }

    /// The public room directory, ready to be searched.
    @MainActor
    func publicRooms() -> PublicRoomDirectory {
        PublicRoomDirectory(search: client.roomDirectorySearch())
    }

    /// Whether `text` is something a room can be found by. The shape only — whether such a room
    /// exists is the server's to say.
    ///
    /// An alias always names its server. A room ID used to, and from room version 12 does not —
    /// `!` and a hash is the whole of it — so a colon is asked of the one and not the other.
    nonisolated static func isRoomAddress(_ text: String) -> Bool {
        let candidate = text.trimmingCharacters(in: .whitespaces)
        guard let sigil = candidate.first, sigil == "#" || sigil == "!", !candidate.contains(" ") else { return false }

        let parts = candidate.dropFirst().split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        if parts.count == 1 { return sigil == "!" && !parts[0].isEmpty }
        return !parts[0].isEmpty && !parts[1].isEmpty
    }

    /// Joins, and waits for the room to be one this device can open — the same wait, for the same
    /// reason, as `create`: the next thing the caller does is put the room on screen.
    private func join(_ idOrAlias: String, via servers: [String]) async throws(RoomJoinFailure) -> String {
        do {
            let client = self.client
            let room = try await withTimeout(Self.joinTimeout) {
                try await client.joinRoomByIdOrAlias(roomIdOrAlias: idOrAlias, serverNames: servers)
            }
            let roomID = room.id()

            _ = try? await withTimeout(.seconds(10)) {
                try await client.awaitRoomRemoteEcho(roomId: roomID)
            }
            return roomID
        } catch {
            Log.rooms.error("the room was not joined: \(Log.describe(error), privacy: .public)")
            throw .refused
        }
    }

    /// Joining over federation is the slowest thing a homeserver does: it may have to fetch the
    /// room's state from a server on the other side of the world.
    private static var joinTimeout: Duration { .seconds(60) }
    private static var directoryTimeout: Duration { .seconds(15) }
}

/// The homeserver's public room directory, page by page.
///
/// The SDK streams it as diffs against an ordered list, like the room list and the timeline, so it
/// is applied the same way: one ordered queue, positional diffs, value types out.
@MainActor
@Observable
public final class PublicRoomDirectory {
    public private(set) var rooms: [PublicRoom] = []
    /// A page is on its way.
    public private(set) var isLoading = false
    /// There is nothing further to fetch for this filter.
    public private(set) var isAtEnd = false
    /// The last request failed. Cleared by the next one.
    public private(set) var failed = false

    @ObservationIgnored private let search: RoomDirectorySearch
    // Touched only on the main actor, and in `deinit`, when nothing else can be touching them.
    @ObservationIgnored nonisolated(unsafe) private var handle: TaskHandle?
    @ObservationIgnored nonisolated(unsafe) private var updates: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    init(search: RoomDirectorySearch) {
        self.search = search
    }

    deinit {
        handle?.cancel()
        updates?.cancel()
    }

    /// Starts over with `filter`. Empty is the whole directory, most populous first.
    public func search(_ filter: String) async {
        await listenIfNeeded()

        generation += 1
        let started = generation
        isLoading = true
        failed = false
        isAtEnd = false

        let trimmed = filter.trimmingCharacters(in: .whitespaces)
        let search = self.search
        do {
            try await withTimeout(.seconds(20)) {
                try await search.search(filter: trimmed.isEmpty ? nil : trimmed, batchSize: 30, viaServerName: nil)
            }
            guard started == generation else { return }
            isAtEnd = (try? await search.isAtLastPage()) ?? true
        } catch {
            guard started == generation else { return }
            Log.rooms.error("the room directory did not answer: \(Log.describe(error), privacy: .public)")
            failed = true
        }
        isLoading = false
    }

    /// The next page, if there is one and none is already coming.
    public func loadMore() async {
        guard !isLoading, !isAtEnd, !failed else { return }
        let started = generation
        isLoading = true

        let search = self.search
        do {
            try await withTimeout(.seconds(20)) { try await search.nextPage() }
            guard started == generation else { return }
            isAtEnd = (try? await search.isAtLastPage()) ?? true
        } catch {
            guard started == generation else { return }
            Log.rooms.error("the room directory did not page: \(Log.describe(error), privacy: .public)")
            failed = true
        }
        isLoading = false
    }

    private func listenIfNeeded() async {
        guard handle == nil else { return }

        let (stream, continuation) = AsyncStream<[RoomDirectorySearchEntryUpdate]>.makeStream()
        updates = Task { @MainActor [weak self] in
            for await batch in stream {
                self?.apply(batch)
            }
        }
        handle = await search.results(listener: DirectoryListener { continuation.yield($0) })
    }

    private func apply(_ batch: [RoomDirectorySearchEntryUpdate]) {
        var list = rooms
        for update in batch {
            switch update {
            case .append(let values): list.append(contentsOf: values.map(PublicRoom.init))
            case .clear: list.removeAll()
            case .pushFront(let value): list.insert(PublicRoom(value), at: 0)
            case .pushBack(let value): list.append(PublicRoom(value))
            case .popFront: if !list.isEmpty { list.removeFirst() }
            case .popBack: if !list.isEmpty { list.removeLast() }
            case .insert(let index, let value): list.insert(PublicRoom(value), at: min(Int(index), list.count))
            case .set(let index, let value): if Int(index) < list.count { list[Int(index)] = PublicRoom(value) }
            case .remove(let index): if Int(index) < list.count { list.remove(at: Int(index)) }
            case .truncate(let length): list = Array(list.prefix(Int(length)))
            case .reset(let values): list = values.map(PublicRoom.init)
            }
        }
        rooms = list
    }
}

private final class DirectoryListener: RoomDirectorySearchEntriesListener {
    private let onUpdate: @Sendable ([RoomDirectorySearchEntryUpdate]) -> Void

    init(_ onUpdate: @escaping @Sendable ([RoomDirectorySearchEntryUpdate]) -> Void) {
        self.onUpdate = onUpdate
    }

    func onUpdate(roomEntriesUpdate: [RoomDirectorySearchEntryUpdate]) {
        onUpdate(roomEntriesUpdate)
    }
}
