import Foundation
import Observation
import MatrixRustSDK

/// Somebody in this room whose keys are not the ones this device remembers for them.
public struct IdentityChange: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        /// New keys for somebody who was never verified. Ordinary — a new phone, a reinstall, a
        /// lost recovery key — and also exactly what a server putting itself in the middle looks
        /// like. Only the person can say which.
        case changed
        /// New keys for somebody this account had *verified*. The serious case: whatever was
        /// checked no longer holds.
        case changedAfterVerification
    }

    public let userID: String
    public let name: String
    public let kind: Kind

    public var id: String { userID }
}

/// The people in one room whose cryptographic identity has changed, and the one thing to do about
/// each: acknowledge it.
///
/// Before this the app said nothing at all. The SDK's default key-sharing strategy sends to a
/// replaced identity without a word, so a message went out to whoever now held those keys — which
/// is fine when it is the person on a new phone, and is the whole attack when it is not. This is
/// the SDK's own signal (`Room.subscribeToIdentityStatusChanges`, the one element-x shows as a
/// banner), carried up to the screen.
///
/// Acknowledging is not verifying. It records the new keys as the ones to expect (`pin()`), or —
/// for somebody who had been verified — withdraws the verification that no longer holds
/// (`withdrawVerification()`), which is what stops the warning coming back. The words on the
/// screen have to say that honestly; this type only does it.
@MainActor
@Observable
public final class IdentityChangesStore {
    /// Oldest first, as they were reported. Never the account's own user: our own identity
    /// changing is the recovery screen's business, not a warning about somebody in the room.
    public private(set) var changes: [IdentityChange] = []

    private let room: Room
    private let encryption: Encryption
    private let ownUserID: String

    private var handle: TaskHandle?
    private var generation = 0
    private var updates: AsyncStream<UnsafeTransfer<[IdentityStatusChange]>>.Continuation?
    private var drain: Task<Void, Never>?

    init(room: Room, encryption: Encryption, ownUserID: String) {
        self.room = room
        self.encryption = encryption
        self.ownUserID = ownUserID
    }

    public func start() async {
        guard handle == nil, updates == nil else { return }
        let generation = self.generation

        // One ordered road from the Rust callback thread, as everywhere else in this app that
        // listens to the SDK: a "changed" and the "pinned" that answers it, applied the wrong way
        // round, would put a warning back up that had just been dealt with.
        let (stream, continuation) = AsyncStream<UnsafeTransfer<[IdentityStatusChange]>>.makeStream()
        updates = continuation
        drain = Task { @MainActor [weak self] in
            for await batch in stream {
                await self?.apply(batch.value)
            }
        }

        let listener = IdentityListener { batch in
            continuation.yield(UnsafeTransfer(value: batch))
        }
        let subscribed = try? await room.subscribeToIdentityStatusChanges(listener: listener)

        // Stopped while subscribing: the handle that just came back is nobody's.
        guard generation == self.generation else {
            subscribed?.cancel()
            return
        }
        handle = subscribed
    }

    public func stop() {
        generation += 1
        handle?.cancel()
        handle = nil
        updates?.finish()
        updates = nil
        drain?.cancel()
        drain = nil
        changes = []
    }

    /// "I know" — the new keys become the ones to expect, and the warning goes.
    ///
    /// Throws, rather than quietly doing nothing, when there is no identity to act on or the SDK
    /// refuses: a warning that seems to go away and comes back on the next launch is worse than
    /// one that stays and says why.
    public func acknowledge(_ change: IdentityChange) async throws {
        guard let identity = try await encryption.userIdentity(userId: change.userID, fallbackToServer: false) else {
            throw IdentityChangeError.unknownIdentity
        }
        switch change.kind {
        case .changed: try await identity.pin()
        case .changedAfterVerification: try await identity.withdrawVerification()
        }
        // The SDK will say so too, as a `pinned` change; taking it down here as well is what
        // makes the banner go the moment the button is pressed rather than a sync later.
        changes.removeAll { $0.userID == change.userID }
    }

    func apply(_ batch: [IdentityStatusChange]) async {
        let generation = self.generation
        for update in batch where update.userId != ownUserID {
            let kind: IdentityChange.Kind? = switch update.changedTo {
            case .pinViolation: .changed
            case .verificationViolation: .changedAfterVerification
            case .pinned, .verified: nil
            }
            guard let kind else {
                changes.removeAll { $0.userID == update.userId }
                continue
            }
            let name = await displayName(of: update.userId)
            // Stopped, or answered, while the name was being looked up.
            guard generation == self.generation else { return }
            let change = IdentityChange(userID: update.userId, name: name, kind: kind)
            if let index = changes.firstIndex(where: { $0.userID == update.userId }) {
                changes[index] = change
            } else {
                changes.append(change)
            }
        }
    }

    private func displayName(of userID: String) async -> String {
        guard let member = try? await room.member(userId: userID) else { return userID }
        return member.displayName ?? userID
    }
}

public enum IdentityChangeError: Error, Sendable {
    /// The SDK has no identity for this person on record — nothing to pin or withdraw.
    case unknownIdentity
}

private final class IdentityListener: IdentityStatusChangeListener {
    private let onChange: @Sendable ([IdentityStatusChange]) -> Void

    init(onChange: @escaping @Sendable ([IdentityStatusChange]) -> Void) {
        self.onChange = onChange
    }

    func call(identityStatusChange: [IdentityStatusChange]) {
        onChange(identityStatusChange)
    }
}
