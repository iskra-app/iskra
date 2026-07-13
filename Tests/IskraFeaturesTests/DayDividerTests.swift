import Testing
import Foundation
@testable import IskraFeatures

/// The words above a day's messages.
///
/// Compared against the same `Strings` the view uses rather than against literal English,
/// so the test says what it means — "this reads as *today*" — in whatever language the
/// machine running it happens to be set to.
@MainActor
struct DayDividerTests {
    private let calendar = Calendar(identifier: .gregorian)

    /// Sunday, 12 July 2026 — the day the weekday came off the divider.
    private var now: Date {
        DateComponents(calendar: calendar, year: 2026, month: 7, day: 12, hour: 15).date!
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 9) -> Date {
        DateComponents(calendar: calendar, year: year, month: month, day: day, hour: hour).date!
    }

    @Test("the two days people name get words, not dates")
    func todayAndYesterday() {
        let today = DayDividerView.label(for: date(2026, 7, 12, hour: 2), now: now, calendar: calendar)
        #expect(today == String(localized: Strings.Room.today))

        let yesterday = DayDividerView.label(for: date(2026, 7, 11), now: now, calendar: calendar)
        #expect(yesterday == String(localized: Strings.Room.yesterday))
    }

    /// The weekday is what this change removed, and a date this year carries no year either.
    @Test("an older day this year is a bare day and month")
    func olderThisYear() {
        let label = DayDividerView.label(for: date(2026, 7, 5), now: now, calendar: calendar)
        #expect(label.contains("5"))
        #expect(!label.contains("2026"))
        #expect(label != String(localized: Strings.Room.today))
        #expect(label != String(localized: Strings.Room.yesterday))
    }

    /// A date in another year has to say which one: "12 июля" three years back dates nothing.
    @Test("a day in another year carries the year")
    func anotherYear() {
        let label = DayDividerView.label(for: date(2023, 7, 12), now: now, calendar: calendar)
        #expect(label.contains("2023"))
    }
}
