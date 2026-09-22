import Foundation

/// The messages the user has pressed send on and the SDK has not echoed back yet.
///
/// The SDK does echo them — a message goes into the encrypted send queue and comes back as a
/// timeline item almost at once, which is what puts the bubble on the screen with a clock beside
/// it. "Almost" is the problem. Between the press and the echo there is a gap of a few hundred
/// milliseconds, and the user spends all of it looking at a composer they have already emptied
/// and a conversation that has not changed: the app appears to have swallowed what they wrote.
///
/// So the words go on the screen *first*, out of here, and the send happens behind them. Each
/// entry is a bubble that exists for no other reason than that somebody typed it, and it lives
/// exactly as long as it takes the real one to arrive.
///
/// The awkward part is knowing when that is. The SDK's echo carries a transaction ID we never
/// see over FFI, so there is nothing to match on but what the message *says* — see
/// `pruneEchoed(in:)`, and the bias written down there.
struct PendingSends: Equatable, Sendable {
    /// One message on its way out.
    struct Pending: Equatable, Sendable, Identifiable {
        /// Distinct from any event ID and any transaction ID, and deliberately unmistakable:
        /// this row is not a message the server knows about, and anything that goes looking for
        /// a send handle by this ID will correctly find nothing.
        let id: String
        /// As typed, trimmed — the same string handed to the SDK, which is what makes the
        /// comparison in `pruneEchoed(in:)` possible at all.
        let text: String
        /// The message being answered, for a reply. A message ID, as everywhere else above the SDK.
        let replyingTo: String?
        let sentAt: Date
    }

    private(set) var all: [Pending] = []

    var isEmpty: Bool { all.isEmpty }

    /// Puts a message on the screen. Returns the ID it was given, so the send that follows can
    /// take it back off again if the SDK refuses it outright.
    @discardableResult
    mutating func add(text: String, replyingTo: String?, at sentAt: Date = .now) -> String {
        let pending = Pending(id: "pending-\(UUID().uuidString)",
                              text: text,
                              replyingTo: replyingTo,
                              sentAt: sentAt)
        all.append(pending)
        return pending.id
    }

    mutating func remove(id: String) {
        all.removeAll { $0.id == id }
    }

    mutating func removeAll() {
        all.removeAll()
    }

    /// Drops the ones the SDK has now echoed, so that the real bubble takes the place of ours
    /// rather than standing beside it.
    ///
    /// Matched on the words, because the words are all there is: the transaction ID that would
    /// identify the echo beyond doubt does not cross the FFI boundary. Two of our own messages
    /// saying the same thing are told apart by *counting* rather than by matching — three
    /// echoes of "ок" retire three pending "ок"s and no more — and only echoes from after we
    /// started sending are considered at all.
    ///
    /// Where the guess has to be wrong, it is wrong in the harmless direction. Retiring a
    /// pending message too eagerly costs the few hundred milliseconds this type exists to save,
    /// and nothing else: the echo it was mistaken for is on the screen, so there is still a
    /// bubble there. Retiring one too late would leave the same sentence in the conversation
    /// twice, which is the failure a reader would actually notice — so the window is generous
    /// and the tie is broken towards forgetting.
    /// Returns which echo took over from which of ours — the real message's ID against the ID
    /// the bubble on the screen already had.
    ///
    /// The pairing is not bookkeeping for its own sake; it is what lets the replacement be
    /// invisible. Our bubble goes up the moment send is pressed and the echo replaces it a
    /// fraction of a second later, and to the screen that is one view being destroyed and
    /// another built in its place — which threw away a message's arrival animation somewhere in
    /// the middle of it, so a message you sent appeared and one somebody sent you rose into
    /// place. Told which is which, the conversation can keep the *same* row and change what is
    /// in it. See `TimelineStore.viewIdentity(of:)`.
    @discardableResult
    mutating func pruneEchoed(in rows: [TimelineRow]) -> [String: String] {
        guard let earliest = all.map(\.sentAt).min() else { return [:] }

        let since = earliest.addingTimeInterval(-Self.echoWindow)
        // In order, and per message ID rather than only counted, so that the second echo of "ок"
        // is paired with the second "ок" we are holding and not with the first.
        var echoes: [String: [String]] = [:]
        for row in rows {
            guard let message = row.message,
                  message.isOwn,
                  message.timestamp >= since,
                  case let .text(body) = message.kind else { continue }
            echoes[body, default: []].append(message.id)
        }

        var taken: [String: String] = [:]
        all.removeAll { pending in
            guard var waiting = echoes[pending.text], !waiting.isEmpty else { return false }
            taken[waiting.removeFirst()] = pending.id
            echoes[pending.text] = waiting
            return true
        }
        return taken
    }

    /// Anything still waiting after this long is given up on rather than left on the screen.
    ///
    /// Not a failure and not reported as one: the message is in the SDK's encrypted send queue,
    /// which is what actually guarantees it goes, and it will appear as an ordinary bubble the
    /// moment the timeline catches up. This only decides how long *our* stand-in is allowed to
    /// wait for it — long enough that no ordinary send is ever cut short, short enough that a
    /// stand-in nothing ever came to replace does not sit in the conversation for good.
    static let lifetime: Duration = .seconds(15)

    /// How far back of the conversation an echo of ours might be hiding in.
    ///
    /// Clock skew, a queue that was paused, a message written while offline and sent when the
    /// network came back: the echo's timestamp is the SDK's, not ours, and it is not obliged to
    /// be later than the moment we pressed send. See the bias in `pruneEchoed(in:)`.
    private static let echoWindow: TimeInterval = 120
}
