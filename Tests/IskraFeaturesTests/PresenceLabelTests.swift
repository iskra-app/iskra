import Testing
import Foundation
@testable import IskraCore
@testable import IskraFeatures

/// The line under somebody's name, read in both languages from a machine running in one.
///
/// That is the whole reason this file exists rather than a glance at a phone: the last relative
/// time this app shipped rendered as **`-3 мин`** in Russian and nobody saw it for weeks, because
/// nobody was reading the app in the language it was wrong in. See `RoomTimestamp`.
struct PresenceLabelTests {
    private let ru = Locale(identifier: "ru")
    private let en = Locale(identifier: "en")

    /// A fixed calendar and a fixed clock, both pinned to one time zone. "Yesterday" is a
    /// question about midnights, so a test that asks it from whatever zone the machine happens to
    /// be in is a test that passes in Moscow and fails in a CI runner set to UTC.
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Moscow") ?? .gmt
        return calendar
    }()

    private func date(day: Int, hour: Int) -> Date {
        calendar.date(from: DateComponents(year: 2023, month: 11, day: day, hour: hour)) ?? .distantPast
    }

    /// Midday, deliberately: from noon, "thirty hours ago" lands yesterday morning rather than
    /// straddling two midnights and meaning whichever the reader assumed.
    private var now: Date { date(day: 15, hour: 12) }

    private func presence(minutesAgo: Double, state: Presence.State = .offline) -> Presence {
        Presence(state: state, lastActive: now.addingTimeInterval(-minutesAgo * 60), isCurrentlyActive: false)
    }

    @Test func currentlyActiveOutranksEverything() {
        // Including a `lastActive` from last week: `currently_active` is the server's own claim
        // about right now, and `state` is a thing a client can set and then walk away from.
        let here = Presence(state: .offline, lastActive: now.addingTimeInterval(-600_000), isCurrentlyActive: true)
        #expect(PresenceLabel.label(for: here, now: now, locale: ru) == "в сети")
        #expect(PresenceLabel.label(for: here, now: now, locale: en) == "online")
    }

    @Test func minutesReadTheWayTheUserAskedForThem() {
        let five = presence(minutesAgo: 5)
        #expect(PresenceLabel.label(for: five, now: now, locale: ru) == "был(а) 5 мин назад")
        #expect(PresenceLabel.label(for: five, now: now, locale: en) == "last seen 5 min ago")
    }

    /// The half of the Russian problem that the abbreviation solves: `мин` does not decline, so
    /// one, two and five take the same word and no `.stringsdict` entry is needed to say so. One
    /// is the case a plural rule gets wrong first.
    @Test func russianMinutesDoNotDecline() {
        for minutes in [1, 2, 5, 11, 21, 59] {
            let label = PresenceLabel.label(for: presence(minutesAgo: Double(minutes)), now: now, locale: ru)
            #expect(label == "был(а) \(minutes) мин назад")
        }
    }

    @Test func underAMinuteIsJustNow() {
        let recent = Presence(state: .offline, lastActive: now.addingTimeInterval(-20), isCurrentlyActive: false)
        #expect(PresenceLabel.label(for: recent, now: now, locale: ru) == "был(а) только что")
        #expect(PresenceLabel.label(for: recent, now: now, locale: en) == "last seen just now")
    }

    @Test func clocksThatDisagreeDoNotProduceNegativeMinutes() {
        // A homeserver's clock and a phone's disagree by a few seconds far more often than either
        // is wrong. Unclamped this renders as "был(а) -1 мин назад", which is how the *last*
        // relative time in this app went wrong.
        let future = Presence(state: .offline, lastActive: now.addingTimeInterval(45), isCurrentlyActive: false)
        #expect(PresenceLabel.label(for: future, now: now, locale: ru) == "был(а) только что")
    }

    @Test func hoursStopBeingUsefulAtHalfADay() {
        let threeHours = presence(minutesAgo: 180)
        #expect(PresenceLabel.label(for: threeHours, now: now, locale: ru) == "был(а) 3 ч назад")
        #expect(PresenceLabel.label(for: threeHours, now: now, locale: en) == "last seen 3 hr ago")

        // Past twelve hours "был(а) 19 ч назад" is arithmetic rather than an answer, so the label
        // switches to the kind of thing a person would say: a time, or a date.
        let yesterday = presence(minutesAgo: 60 * 30)
        #expect(PresenceLabel.label(for: yesterday, now: now, calendar: calendar, locale: ru) == "был(а) вчера")
        #expect(PresenceLabel.label(for: yesterday, now: now, calendar: calendar, locale: en) == "last seen yesterday")

        // Earlier the same day, and past twelve hours: a clock time, because that is what somebody
        // would say about this morning. Only reachable late in the day — from noon, twelve hours
        // back is already yesterday — so this one asks from eleven at night about eight in the
        // morning.
        let lateEvening = date(day: 15, hour: 23)
        let thisMorning = Presence(state: .offline,
                                   lastActive: date(day: 15, hour: 8),
                                   isCurrentlyActive: false)
        let morning = PresenceLabel.label(for: thisMorning, now: lateEvening, calendar: calendar, locale: ru)
        #expect(morning?.hasPrefix("был(а) в ") == true)
    }

    @Test func longAgoIsADate() {
        let weekAgo = presence(minutesAgo: 60 * 24 * 7)

        let russian = PresenceLabel.label(for: weekAgo, now: now, calendar: calendar, locale: ru)
        let english = PresenceLabel.label(for: weekAgo, now: now, calendar: calendar, locale: en)

        // The date itself is the locale's to format — what is pinned here is the words in front of
        // it, and that a date is what comes out at all.
        #expect(russian?.hasPrefix("был(а) ") == true)
        #expect(english?.hasPrefix("last seen ") == true)
        #expect(russian?.contains("мин") == false)
    }

    /// The common case, and the one the header has to survive: nothing to say.
    @Test func aServerThatSaysNothingDrawsNothing() {
        let silent = Presence(state: .offline, lastActive: nil, isCurrentlyActive: false)
        #expect(PresenceLabel.label(for: silent, now: now, locale: ru) == nil)
        #expect(PresenceLabel.label(for: silent, now: now, locale: en) == nil)
    }
}
