import Foundation
import Observation
import MatrixRustSDK

/// The kinds of thing the app keeps on this device.
///
/// Three, because there are three stores and they answer three different questions — and the
/// difference between them is exactly what a person deciding whether to press "clear" needs to
/// know. Losing the cache costs a download. Losing the search index costs a rebuild. Losing the
/// session data costs the device's identity in the room, which is why nothing here offers to.
public enum StorageKind: String, Sendable, CaseIterable, Identifiable {
    /// The crypto store, the room state, the send queue. Not disposable: these are the keys this
    /// device decrypts with, and the messages waiting to go out.
    case session

    /// Events and media the SDK has downloaded. Disposable by design — the SDK rebuilds it from
    /// the server, which is why this is the one the button clears.
    case cache

    /// The local full-text index. Disposable too, in that it can be rebuilt from the messages —
    /// but it is rebuilt by *reading them again*, not by asking the server for it.
    case search

    public var id: String { rawValue }
}

/// How much room one of them takes.
public struct StorageAmount: Sendable, Identifiable, Equatable {
    public let kind: StorageKind
    public let bytes: Int64

    public var id: StorageKind { kind }
}

/// What the app is keeping on this device, and the one way to get some of it back.
///
/// Made per screen rather than owned by the session: nothing else needs it, and the answer is
/// stale the moment it is given anyway — the SDK writes to these stores continuously.
@MainActor
@Observable
public final class StorageStore {
    public private(set) var amounts: [StorageAmount] = []
    public private(set) var isMeasuring = false
    public private(set) var isClearing = false

    /// Everything, including the parts the button will not touch.
    public var total: Int64 { amounts.reduce(0) { $0 + $1.bytes } }

    /// What clearing the cache would actually win back. Shown on the button, because "clear
    /// cache" without a number is asking someone to take an action whose only visible effect is
    /// that their photos have to download again.
    public var reclaimable: Int64 {
        amounts.first { $0.kind == .cache }?.bytes ?? 0
    }

    private let client: Client
    private let roomList: RoomListStore
    private let locations: [StorageKind: URL]

    init(client: Client, roomList: RoomListStore, locations: [StorageKind: URL]) {
        self.client = client
        self.roomList = roomList
        self.locations = locations
    }

    /// Adds up what is on disk.
    ///
    /// Off the main actor, and not because a few directories are slow to walk: the media cache of
    /// a well-used account is thousands of files, and the walk is a `stat` apiece. On the main
    /// actor that is a settings screen that hangs while it opens.
    public func measure() async {
        isMeasuring = true
        defer { isMeasuring = false }

        let locations = locations.mapValues(\.path)
        let measured = await Task.detached(priority: .utility) {
            StorageKind.allCases.compactMap { kind -> StorageAmount? in
                guard let path = locations[kind] else { return nil }
                return StorageAmount(kind: kind, bytes: Self.size(ofDirectoryAt: path))
            }
        }.value

        amounts = measured
    }

    /// Throws the cache away — the SDK's, not ours by hand.
    ///
    /// Deliberately `Client.clearCaches` rather than deleting the directory. The app is *running*
    /// while this is pressed: the client holds those SQLite files open, the sync loop is writing
    /// to them, and pulling them out from underneath it leaves a live client reading from a file
    /// that no longer exists.
    ///
    /// **The client this ran on is finished afterwards, and the caller must replace it.** The SDK
    /// says so plainly — "the Client will be in an unstable state, and it is required that the
    /// caller reinstantiates a new Client instance" — and this was the whole of why the button
    /// appeared to do nothing: the cache really was emptied, and the app went on talking to a
    /// client whose store had been pulled out from under it. So the screen that presses this hands
    /// the app back to `restore()`, which builds a client afresh from the session in the Keychain.
    /// Nothing is signed out: the tokens and the keys are untouched, only what could be downloaded
    /// again is gone.
    ///
    /// And then the directory itself goes, which is not belt-and-braces — it is the only part of
    /// this that gives the space back.
    ///
    /// `clearCaches` empties the *tables*. SQLite frees those pages inside its own file and hands
    /// nothing back to the filesystem: the rows are gone, the messages and the photos are gone,
    /// and the file on disk is exactly as many megabytes as it was. So the screen went on
    /// reporting twenty-two megabytes over an empty cache, and it was not wrong — that is what the
    /// cache was *taking*, which is the question the screen asks. Vacuuming would be the tidy
    /// answer and we cannot: the client that owns the connection is, by this point, deliberately
    /// dead.
    ///
    /// Which is exactly what makes deleting the directory safe, and it is the one moment it ever
    /// is. Nothing is holding those files open with any intention of using them again: the sync
    /// service is down, the client is unusable by the SDK's own account, and the caller is about
    /// to build a new one — which recreates the directory on its way up. This is the window, and
    /// there is no other.
    public func clearCache() async throws {
        isClearing = true
        defer { isClearing = false }

        try await client.clearCaches(syncService: roomList.currentSyncService)

        if let cache = locations[.cache] {
            try? FileManager.default.removeItem(at: cache)
        }

        await measure()
    }

    /// The size of a directory tree, in bytes on disk.
    ///
    /// `totalFileAllocatedSize` rather than `fileSize`: the question being answered is the one the
    /// Settings app answers — how much of the phone this is using — and a thousand small files use
    /// more of it than the sum of their contents. A file the enumerator cannot stat is counted as
    /// nothing rather than refusing the whole answer; a storage screen that says "unavailable"
    /// because one file moved while it was being read is worse than one that is a block short.
    nonisolated private static func size(ofDirectoryAt path: String) -> Int64 {
        let url = URL(fileURLWithPath: path)
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]

        guard let files = FileManager.default.enumerator(at: url,
                                                         includingPropertiesForKeys: Array(keys),
                                                         options: [.skipsHiddenFiles]) else {
            return 0
        }

        var total: Int64 = 0
        for case let file as URL in files {
            guard let values = try? file.resourceValues(forKeys: keys),
                  values.isRegularFile == true else { continue }
            let size = values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0
            total += Int64(size)
        }
        return total
    }
}
