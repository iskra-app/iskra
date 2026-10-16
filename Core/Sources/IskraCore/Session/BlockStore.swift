import Foundation
import Observation
import MatrixRustSDK

/// Who the user has blocked, and the two acts that change it.
///
/// "Block" in the app is Matrix's *ignore*: a server-side list, so it follows the account to every
/// device, and the homeserver itself stops delivering the blocked person's messages into sync. The
/// SDK hides them from timelines that are already open, too. That is why blocking is one call and no
/// per-room bookkeeping — it is a fact about the account, not about any one conversation.
///
/// It is one-directional, and honestly so: blocking someone hides *them from you*. Matrix has no way
/// for a client to stop a person from sending — ignore is about what you receive. The UI says
/// "block", because that is the word people reach for, but it does not promise more than the
/// protocol delivers.
@MainActor
@Observable
public final class BlockStore {
    /// The blocked Matrix IDs, kept in step by a live subscription so a block made on another device
    /// shows here too.
    public private(set) var blockedUserIDs: [String] = []

    /// A block or unblock that would not take.
    public var failure: AccountActionFailure?

    private let client: Client
    private var subscription: TaskHandle?

    init(client: Client) {
        self.client = client

        // The current list, then a subscription for every change after it. The listener hops to the
        // main actor with a plain `[String]` — nothing non-Sendable crosses.
        let listener = IgnoredUsersUpdateListener { [weak self] ids in
            Task { @MainActor in self?.blockedUserIDs = ids.sorted() }
        }
        subscription = client.subscribeToIgnoredUsers(listener: listener)

        Task { [weak self] in
            guard let ids = try? await client.ignoredUsers() else { return }
            await MainActor.run { self?.blockedUserIDs = ids.sorted() }
        }
    }

    /// Blocks a user — Matrix's `ignoreUser`. Their messages stop arriving and the ones on screen
    /// are hidden by the SDK.
    public func block(userID: String) async {
        do {
            try await client.ignoreUser(userId: userID)
        } catch {
            Log.session.error("could not block a user: \(Log.describe(error), privacy: .public)")
            failure = .block
        }
    }

    /// Lifts a block.
    public func unblock(userID: String) async {
        do {
            try await client.unignoreUser(userId: userID)
        } catch {
            Log.session.error("could not unblock a user: \(Log.describe(error), privacy: .public)")
            failure = .unblock
        }
    }

    public func isBlocked(_ userID: String) -> Bool {
        blockedUserIDs.contains(userID)
    }
}

/// Bridges the SDK's ignored-users callback to a plain closure. The list of IDs is `Sendable`, so
/// nothing here needs the `UnsafeTransfer` the diff listeners use.
private final class IgnoredUsersUpdateListener: IgnoredUsersListener {
    private let onChange: @Sendable ([String]) -> Void

    init(onChange: @escaping @Sendable ([String]) -> Void) {
        self.onChange = onChange
    }

    func call(ignoredUserIds: [String]) {
        onChange(ignoredUserIds)
    }
}
