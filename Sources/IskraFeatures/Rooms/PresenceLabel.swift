import Foundation
import IskraCore

/// «в сети» · «был(а) 5 мин назад» · «был(а) в 10:20» · «был(а) 12.07.25».
///
/// The one place the app turns a timestamp into a claim about where somebody is, kept apart from
/// the header that shows it so that it can be read in both languages by a test rather than by
/// squinting at a phone — which is the lesson `RoomTimestamp` was written down after.
///
/// **«мин», not «минут».** The abbreviation is the user's own wording and it happens to solve the
/// harder half of the problem for free: Russian would otherwise need one/few/many for every unit
/// and a `.stringsdict` entry to express them, and `5 минут / 2 минуты / 1 минута` is exactly the
/// kind of thing that gets one case wrong and ships. Abbreviations do not decline. The gendered
/// half is not so easily dodged — Matrix has no notion of a user's gender and neither has this app
/// — so it is «был(а)», which is what every Russian client settles on for the same reason.
///
/// Nil means say nothing, and that is the common case: presence is off on many homeservers
/// (matrix.org among them), and that arrives here as a `Presence` that is not worth showing. The
/// header draws what it always drew.
enum PresenceLabel {
    /// `now`, `calendar` and `locale` are parameters for the same reason `RoomTimestamp`'s are:
    /// a label about time that can only be checked by waiting is a label nobody checks.
    static func label(for presence: Presence,
                      now: Date = .now,
                      calendar: Calendar = .current,
                      locale: Locale = .current) -> String? {
        // The server's own word for "right now" outranks everything below. `state` alone does not:
        // a client can announce `online` and its owner can then put the phone down for a week.
        if presence.isCurrentlyActive || presence.state == .online {
            return text(Strings.Presence.online, in: locale)
        }

        guard let lastActive = presence.lastActive else { return nil }

        // Clamped at zero. A homeserver's clock and this device's clock disagree by a few seconds
        // more often than either is wrong, and a negative age renders as "был(а) -1 мин назад".
        let ago = max(0, now.timeIntervalSince(lastActive))

        if ago < 60 {
            return text(Strings.Presence.justNow, in: locale)
        }

        if ago < 3600 {
            return text(Strings.Presence.minutesAgo(Int(ago / 60)), in: locale)
        }

        // Twelve, not twenty-four: "был(а) 19 ч назад" is arithmetic, not an answer. Past half a
        // day people think in clock times and dates, which is what the two branches below give.
        if ago < 12 * 3600 {
            return text(Strings.Presence.hoursAgo(Int(ago / 3600)), in: locale)
        }

        if calendar.isDate(lastActive, inSameDayAs: now) {
            let time = lastActive.formatted(.dateTime.hour().minute().locale(locale))
            return text(Strings.Presence.atTime(time), in: locale)
        }

        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(lastActive, inSameDayAs: yesterday) {
            return text(Strings.Presence.yesterday, in: locale)
        }

        // Numeric, so it is read rather than parsed: 12.07.25 in Russian, 07/12/25 in English.
        let date = lastActive.formatted(.dateTime.day(.twoDigits).month(.twoDigits).year(.twoDigits)
            .locale(locale))
        return text(Strings.Presence.at(date), in: locale)
    }

    /// `String(localized:locale:)` cannot be used here: with a `LocalizedStringResource` that
    /// overload resolves to the one taking a `LocalizationValue` and does not compile. The locale
    /// goes on the resource itself, which is also how `LocalizationTests` reads every string in
    /// both languages from a machine running in one.
    private static func text(_ resource: LocalizedStringResource, in locale: Locale) -> String {
        var resource = resource
        resource.locale = locale
        return String(localized: resource)
    }
}
