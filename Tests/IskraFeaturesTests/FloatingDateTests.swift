import Foundation
import Testing
@testable import IskraFeatures

/// The date floating over a scrolling room is the latest day whose header has gone above the top
/// of the screen — worked out from crossings alone, without asking where every row is.
@Suite("Floating date")
struct FloatingDateTests {
    private let monday = Date(timeIntervalSince1970: 1_800_000_000)
    private var tuesday: Date { monday.addingTimeInterval(86_400) }
    private var wednesday: Date { monday.addingTimeInterval(2 * 86_400) }

    @Test("nothing floats while every date is still on the screen")
    func nothingAbove() {
        #expect(FloatingDates().current == nil)
    }

    @Test("the latest date above the line is the one floating")
    func latestAbove() {
        var dates = FloatingDates()
        dates.date(monday, isAbove: true)
        dates.date(tuesday, isAbove: true)
        #expect(dates.current == tuesday)
    }

    @Test("scrolling back up past a date hands the float to the day before")
    func scrollingBack() {
        var dates = FloatingDates()
        dates.date(monday, isAbove: true)
        dates.date(tuesday, isAbove: true)
        dates.date(wednesday, isAbove: true)
        dates.date(wednesday, isAbove: false)
        #expect(dates.current == tuesday)
    }

    @Test("the same crossing twice changes nothing")
    func idempotent() {
        var once = FloatingDates()
        once.date(monday, isAbove: true)
        var twice = once
        twice.date(monday, isAbove: true)
        #expect(once == twice)
    }
}
