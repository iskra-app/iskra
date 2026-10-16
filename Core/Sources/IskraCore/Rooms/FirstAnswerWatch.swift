import MatrixRustSDK

/// The rules behind "Updating…" and "Waiting for network" while sync has come up and the server
/// has not yet answered — see `RoomListStore.watchFirstAnswer`, which owns the timer.
///
/// Kept apart from the store so the rules can be asked about without a client: which room-list
/// states mean the server has answered, and when the wait counts at all.
enum FirstAnswerWatch {
    /// How long the server may take before "Updating…" — the same half second the SDK's own
    /// indicator waits, so a catch-up that is over before anyone could read the word never shows it.
    static let updatingAfter: Duration = .milliseconds(500)

    /// How long it may take before the title stops saying "Updating…" and says "Waiting for
    /// network" instead. The SDK gives one sync request a whole minute and then retries it; by a
    /// quarter of that, somebody looking at a list that has not moved deserves to be told why.
    static let stalledAfter: Duration = .seconds(12)

    /// Whether this room-list state is one the SDK records only *after* a request has come back.
    ///
    /// The SDK computes the next state, makes the request, and stores the state only on success —
    /// so `settingUp`, `recovering` and `running` all mean the server has answered since sync last
    /// came up. `terminated` is what a pause leaves behind, `error` is a failed request, and
    /// `initial` is a list that has never asked; none of them has heard anything.
    static func answered(_ state: RoomListServiceState) -> Bool {
        switch state {
        case .settingUp, .recovering, .running: true
        case .initial, .terminated, .error: false
        }
    }

    /// Whether there is anything to wait for. Not while sync is down on purpose, and not while the
    /// SDK has already said it is offline — that is said on screen already, and in stronger words.
    static func isWaiting(stopped: Bool, paused: Bool, offline: Bool, answered: Bool) -> Bool {
        !stopped && !paused && !offline && !answered
    }
}
