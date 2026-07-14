import Foundation

/// When the last thing in a room was said, as a chat list says it: `14:32`, `Вчера`, `пт`, `12.07.25`.
///
/// It used to be `.relative(presentation: .numeric, unitsStyle: .narrow)`, and in Russian that
/// renders as **`-3 мин`** — with a minus in front. Nothing is miscalculated: CLDR's *narrow*
/// relative patterns for Russian are literally `-{0} мин.` for the past and `+{0} мин.` for the
/// future, where English spends the extra characters on `3 min. ago`. Narrow is a format for axis
/// labels and dense tables, and a chat list is neither; asking for it in every locale and reading
/// the result in one is how it went unnoticed.
///
/// Widening the style would have removed the minus and left the worse half of the bug standing:
/// `Text(date, format: .relative(…))` is rendered once and never again. SwiftUI has no reason to
/// redraw a row whose data has not changed, so "3 мин" stays "3 мин" while the hour goes by, and
/// the only thing that ever corrected it was an unrelated update to the same room. A clock time is
/// simply true whenever it is read.
///
/// So the rule is the one every chat list has settled on, and it is a rule about *how people ask*.
/// Today the question is what time — so the answer is the time. Beyond today it is which day, and
/// the answer gets shorter as the day gets less distinct: yesterday has a name, the last week has
/// weekdays, and past that a date is the only thing that identifies anything.
enum RoomTimestamp {
    /// `locale` is a parameter and not simply `.current` inside, so that the tests can ask what this
    /// says *in Russian* while running on an English machine. That is not a detail: the whole bug
    /// was a label nobody had read in the language it was wrong in.
    static func label(for date: Date,
                      now: Date = .now,
                      calendar: Calendar = .current,
                      locale: Locale = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return date.formatted(.dateTime.hour().minute().locale(locale))
        }

        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return String(localized: Strings.Room.yesterday)
        }

        // Six days, not seven. At seven, "вторник" could mean this Tuesday or the one before it,
        // and a label that names the wrong week is worse than a date that names none.
        //
        // Counted in *days*, from midnight to midnight, rather than in 144 hours: whether a message
        // is "Friday" or "08.07" cannot depend on the time of day it was sent, and `timeIntervalSince`
        // would have it flip at breakfast.
        let days = calendar.dateComponents([.day],
                                           from: calendar.startOfDay(for: date),
                                           to: calendar.startOfDay(for: now)).day ?? 0
        if (0...6).contains(days) {
            return date.formatted(.dateTime.weekday(.abbreviated).locale(locale))
        }

        // Numeric, so it is read rather than parsed: 12.07.25 in Russian, 07/12/25 in English,
        // each the shape its reader already knows.
        return date.formatted(.dateTime.day(.twoDigits).month(.twoDigits).year(.twoDigits)
            .locale(locale))
    }
}
