import Foundation

/// The calls this device has already rung about, written where the other process can see them.
///
/// ## The bug this exists to prevent
///
/// A ringing call arrives **twice**. Push rules do not route per pusher, so the same
/// `m.rtc.notification` becomes a VoIP push (which rings) and an ordinary push (which wakes the
/// notification extension). The ordinary copy is meant to come to nothing, and normally does —
/// `PushMapper` returns a named silence for it.
///
/// But the extension has one obligation it cannot skip: it must call its content handler. When it
/// cannot decrypt in time, or at all, what it hands over is `delivery.fallback` — the server's
/// "Новое сообщение". Landing on top of a call that is ringing at that moment, it reads as two
/// unrelated bugs and is one.
///
/// So the app writes the ring's event id here the instant it reports the call, and the extension
/// checks before falling back. Same reasoning as `BetaFeatures.faceStore`: a fact only the app can
/// see is a fact the lock screen silently disobeys.
///
/// ## Why it forgets
///
/// Entries are kept for a few minutes and then dropped. This is a hand-off between two processes
/// that are awake at the same moment, not a history — an unbounded list in shared defaults would
/// grow for the life of the install, and a stale id in it would silence a genuine notification
/// about an event that happens to reuse it.
public enum RingLedger {
    static let key = "calls.ringing"

    /// How long an entry is worth anything. Generous next to the seconds the two processes
    /// actually overlap by, and short enough that nothing accumulates.
    static let memory: TimeInterval = 5 * 60

    /// Where both processes can reach it. Nil in a standalone build with no App Group, and then
    /// nothing is written and nothing is checked — which is correct, because such a build has no
    /// notification extension either.
    public static var store: UserDefaults? { ChatDirectory.sharedDefaults }

    /// Says that this device has taken charge of ringing about this event.
    public static func reported(eventID: String,
                                at moment: Date = Date(),
                                in defaults: UserDefaults? = store) {
        guard let defaults else { return }
        var table = self.table(in: defaults)
        table[eventID] = moment.timeIntervalSince1970
        defaults.set(prune(table, at: moment), forKey: key)
    }

    /// Whether the app is already ringing about this event, so the extension should stay quiet.
    public static func isRinging(eventID: String,
                                 at moment: Date = Date(),
                                 in defaults: UserDefaults? = store) -> Bool {
        guard let defaults, let written = table(in: defaults)[eventID] else { return false }
        return moment.timeIntervalSince1970 - written < memory
    }

    /// Forgets one, once the call is over. Not required for correctness — entries expire on their
    /// own — but a call that ended thirty seconds ago should not go on silencing anything.
    public static func ended(eventID: String, in defaults: UserDefaults? = store) {
        guard let defaults else { return }
        var table = self.table(in: defaults)
        table[eventID] = nil
        defaults.set(table, forKey: key)
    }

    private static func table(in defaults: UserDefaults) -> [String: TimeInterval] {
        defaults.dictionary(forKey: key) as? [String: TimeInterval] ?? [:]
    }

    private static func prune(_ table: [String: TimeInterval], at moment: Date) -> [String: TimeInterval] {
        table.filter { moment.timeIntervalSince1970 - $0.value < memory }
    }
}
