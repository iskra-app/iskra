import CoreLocation
import Foundation
import Testing
@testable import IskraCore

/// When a live share sends a point — see `LiveLocationSharer.shouldSend`.
@Suite("Live location")
struct LiveLocationTests {
    private let here = CLLocation(latitude: 55.7558, longitude: 37.6173)

    @Test("the first point always goes")
    func first() {
        #expect(LiveLocationSharer.shouldSend(here, after: nil))
    }

    @Test("standing still sends nothing until the silence is long enough")
    func still() {
        let now = Date()
        let last = (location: here, at: now.addingTimeInterval(-20))
        #expect(!LiveLocationSharer.shouldSend(here, after: last, now: now))
        let old = (location: here, at: now.addingTimeInterval(-LiveLocationSharer.maximumSilence - 1))
        #expect(LiveLocationSharer.shouldSend(here, after: old, now: now))
    }

    @Test("moving far enough sends")
    func moving() {
        let now = Date()
        let there = CLLocation(latitude: 55.7562, longitude: 37.6173)   // ~45 m north
        #expect(LiveLocationSharer.shouldSend(there, after: (here, now), now: now))
    }

    @Test("a share is active until it is stopped or its time is up")
    func span() {
        let now = Date()
        #expect(Location.LiveSpan(isLive: true, until: now.addingTimeInterval(60), updatedAt: nil).isActive(now: now))
        #expect(!Location.LiveSpan(isLive: true, until: now.addingTimeInterval(-1), updatedAt: nil).isActive(now: now))
        #expect(!Location.LiveSpan(isLive: false, until: now.addingTimeInterval(60), updatedAt: now).isActive(now: now))
    }
}
