import Foundation

/// The reactions we put on a message and could not send.
///
/// The SDK does not take them back. A reaction goes into the same encrypted send queue as a
/// message, and the timeline echoes it immediately — but when the send fails, the echo *stays*:
/// the Rust timeline records the failure against the reaction's send handle and leaves the
/// aggregation alone. Over FFI we cannot even see that much, because `ReactionSenderData`
/// carries a sender and a timestamp and no status at all.
///
/// So the pill lights up as ours and stays lit, on a reaction that reached nobody. This is the
/// record of those, and `applied(to:)` is what keeps them off the screen: our own vote is taken
/// back out of the pill, and if we were the only one holding it up, the pill goes with it.
///
/// Keyed by message and emoji rather than by anything the SDK hands back, because the SDK hands
/// nothing back — see `TimelineStore.toggleReaction`.
struct UnsentReactions: Equatable, Sendable {
    private var keysByMessage: [String: Set<String>] = [:]

    var isEmpty: Bool { keysByMessage.isEmpty }

    func contains(messageID: String, key: String) -> Bool {
        keysByMessage[messageID]?.contains(key) ?? false
    }

    mutating func insert(messageID: String, key: String) {
        keysByMessage[messageID, default: []].insert(key)
    }

    /// Forgets one, because the user is trying it again. The pill it was hiding comes straight
    /// back — which is right: the reaction is on its way once more, and this time it may land.
    mutating func remove(messageID: String, key: String) {
        keysByMessage[messageID]?.remove(key)
        if keysByMessage[messageID]?.isEmpty == true { keysByMessage[messageID] = nil }
    }

    /// Everything held, so that restarting the send queue can put all of it back in flight.
    ///
    /// The queue is first-in-first-out and it stops dead on an error — which is why a failure
    /// belonging to somebody's *message* also strands every reaction queued behind it. The
    /// mirror image is just as true and used not to be acted on: when the queue is started
    /// again, everything in it goes, reactions included. They are not unsent any more; they are
    /// in flight. See `TimelineStore.requeueUnsentReactions`.
    var all: [(messageID: String, key: String)] {
        keysByMessage.flatMap { message, keys in keys.map { (message, $0) } }
    }

    mutating func removeAll() {
        keysByMessage.removeAll()
    }

    /// Subtracts us from the reactions on one message.
    ///
    /// Only our own vote is removed. Other people's reactions with the same emoji are theirs and
    /// really are on the server: a pill that reads "👍 2" when two other people pressed it and we
    /// failed to becomes "👍 2" — not empty, and not "👍 3".
    func applied(to reactions: [MessageReaction], messageID: String) -> [MessageReaction] {
        guard let keys = keysByMessage[messageID], !keys.isEmpty else { return reactions }

        return reactions.compactMap { reaction in
            guard keys.contains(reaction.key), reaction.isMine else { return reaction }

            let remaining = reaction.count - 1
            guard remaining > 0 else { return nil }
            return MessageReaction(key: reaction.key, count: remaining, isMine: false)
        }
    }
}
