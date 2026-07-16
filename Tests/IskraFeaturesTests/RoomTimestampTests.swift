import Testing
import Foundation
@testable import IskraFeatures

// Fixtures build dates from hardcoded, valid `DateComponents`. A nil there is a broken test with a
// name pointing straight at it, not a runtime path — the force-unwrap is the right thing to write.
// swiftlint:disable force_unwrapping

/// The time beside a room in the chat list.
@MainActor
struct RoomTimestampTests {
    private let calendar = Calendar(identifier: .gregorian)

    /// Sunday, 12 July 2026, quarter past three.
    private var now: Date {
        DateComponents(calendar: calendar, year: 2026, month: 7, day: 12, hour: 15, minute: 15).date!
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 9, minute: Int = 32) -> Date {
        DateComponents(calendar: calendar, year: year, month: month, day: day,
                       hour: hour, minute: minute).date!
    }

    /// The bug as it was reported: "-3 мин" in the Russian build, with a minus in front of it.
    ///
    /// Asserted against every label this type can produce, in both languages, because the minus did
    /// not come from any arithmetic here — it is what CLDR's *narrow* relative style spells in
    /// Russian, and it would come back the moment somebody reached for `.relative` again.
    @Test("no label anywhere is signed")
    func nothingIsSigned() {
        let moments = [date(2026, 7, 12, hour: 15, minute: 12),  // three minutes ago
                       date(2026, 7, 11),                        // yesterday
                       date(2026, 7, 8),                         // this week
                       date(2026, 6, 2),                         // this year
                       date(2023, 1, 9)]                         // years back

        for identifier in ["ru_RU", "en_US"] {
            let locale = Locale(identifier: identifier)

            for moment in moments {
                let label = RoomTimestamp.label(for: moment, now: now,
                                                calendar: calendar, locale: locale)
                #expect(!label.contains("-"), "\(label) (\(identifier))")
                #expect(!label.contains("−"), "\(label) (\(identifier))")  // U+2212, the real minus
                #expect(!label.contains("+"), "\(label) (\(identifier))")
            }
        }
    }

    /// Today the question is *what time*, so the answer is the time — and it is the same sentence an
    /// hour later, which `.relative` was not.
    @Test("a message from today is given a clock time")
    func today() {
        let label = RoomTimestamp.label(for: date(2026, 7, 12, hour: 14, minute: 32),
                                        now: now, calendar: calendar)
        #expect(label.contains("32"))
        #expect(label.contains("14") || label.contains("2"))  // 14:32, or 2:32 PM
    }

    @Test("yesterday is a word")
    func yesterday() {
        let label = RoomTimestamp.label(for: date(2026, 7, 11), now: now, calendar: calendar)
        #expect(label == String(localized: Strings.Room.yesterday))
    }

    /// Within the week a weekday still identifies a day. It has to be a *name*, not a number.
    @Test("the days before that are weekdays")
    func thisWeek() {
        let wednesday = RoomTimestamp.label(for: date(2026, 7, 8), now: now, calendar: calendar)
        #expect(wednesday.contains { $0.isLetter })
        #expect(!wednesday.contains { $0.isNumber })
        #expect(wednesday != String(localized: Strings.Room.yesterday))
    }

    /// The edge, and the reason it is six days and not seven: a week ago today is *Sunday*, and a
    /// label reading "вс" beside it would mean either this Sunday or the last one.
    @Test("a week back is a date, not the same weekday again")
    func aWeekBack() {
        let label = RoomTimestamp.label(for: date(2026, 7, 5), now: now, calendar: calendar)
        #expect(label.contains("05") || label.contains("5"))
        #expect(label.contains("07") || label.contains("7"))
    }

    /// Days, not hours. A message sent late on Saturday and read early on Sunday is one day old by
    /// the clock and two by `timeIntervalSince`, and the label must not depend on which.
    @Test("the day boundary is midnight, not a count of hours")
    func midnightNotHours() {
        let lateYesterday = date(2026, 7, 11, hour: 23, minute: 50)
        let earlyToday = DateComponents(calendar: calendar, year: 2026, month: 7, day: 12,
                                        hour: 0, minute: 30).date!

        let label = RoomTimestamp.label(for: lateYesterday, now: earlyToday, calendar: calendar)
        #expect(label == String(localized: Strings.Room.yesterday))
    }

    @Test("years back, it is a date with a year on it")
    func longAgo() {
        let label = RoomTimestamp.label(for: date(2023, 1, 9), now: now, calendar: calendar)
        #expect(label.contains("23"))
    }
}

// swiftlint:enable force_unwrapping
