import Foundation
import Testing
@testable import IskraCore

/// A video or an album followed past its screen — see `MediaSendJobs`. The queue is played by hand:
/// the bookkeeping is what is tested, and the SDK's half is `MediaSendJobs.event(from:)`.
@Suite("Media send jobs")
@MainActor
struct MediaSendJobsTests {
    private func jobs() -> MediaSendJobs {
        MediaSendJobs(roomFor: { _ in nil },
                      look: { _ in .init(name: "Кухня", avatarSeed: "!kitchen", faceFile: nil) })
    }

    @Test("one photo is not followed; a video, three photos or a big file are")
    func threshold() {
        #expect(!MediaSendJobs.isWorthFollowing([.init()]))
        #expect(!MediaSendJobs.isWorthFollowing([.init(), .init()]))
        #expect(MediaSendJobs.isWorthFollowing([.init(), .init(), .init()]))
        #expect(MediaSendJobs.isWorthFollowing([.init(isVideo: true)]))
        #expect(MediaSendJobs.isWorthFollowing([.init(isFile: true, bytes: 20 * 1024 * 1024)]))
        #expect(!MediaSendJobs.isWorthFollowing([.init(isFile: true, bytes: 1024)]))
        #expect(jobs().begin(roomID: "!r", items: [.init()]) == nil)
    }

    @Test("an album goes preparing → uploading → sent, and the bar only ever moves forward")
    func album() throws {
        let jobs = jobs()
        let id = try #require(jobs.begin(roomID: "!r", items: [.init(), .init(), .init()]))
        #expect(jobs.jobs.first?.what == .photos(3))
        #expect(jobs.jobs.first?.roomName == "Кухня")
        #expect(jobs.jobs.first?.phase == .preparing)
        #expect(jobs.jobs.first?.progress == 0)

        var last = 0.0
        func moved() {
            let now = jobs.jobs.first?.progress ?? 0
            #expect(now >= last)
            last = now
        }

        for transaction in ["t1", "t2", "t3"] {
            jobs.handed(id, accepted: true)
            jobs.receive(.created(transaction), in: "!r")
            moved()
        }
        jobs.doneHanding(id)
        #expect(jobs.jobs.first?.phase == .uploading)
        // Preparation done: its share of the bar is full, the upload's is empty.
        #expect(abs((jobs.jobs.first?.progress ?? 0) - MediaSendJobs.preparationShare) < 0.0001)

        jobs.receive(.progress("t1", 0.5), in: "!r"); moved()
        jobs.receive(.sent("t1"), in: "!r"); moved()
        jobs.receive(.sent("t2"), in: "!r"); moved()
        #expect(jobs.jobs.first?.phase == .uploading)
        jobs.receive(.sent("t3"), in: "!r")
        #expect(jobs.jobs.first?.phase == .sent)
        #expect(jobs.jobs.first?.progress == 1)
    }

    @Test("somebody else's message in another room is not the job's")
    func otherRooms() throws {
        let jobs = jobs()
        let id = try #require(jobs.begin(roomID: "!r", items: [.init(isVideo: true)]))
        jobs.receive(.created("elsewhere"), in: "!other")
        jobs.handed(id, accepted: true)
        jobs.receive(.created("mine"), in: "!r")
        jobs.doneHanding(id)
        // A text typed after the video is not part of it either.
        jobs.receive(.created("words"), in: "!r")
        jobs.receive(.sent("mine"), in: "!r")
        #expect(jobs.jobs.first?.phase == .sent)
    }

    @Test("a final refusal fails the job; a pause for the network does not")
    func failures() throws {
        let jobs = jobs()
        let id = try #require(jobs.begin(roomID: "!r", items: [.init(isVideo: true)]))
        jobs.handed(id, accepted: true)
        jobs.receive(.created("t"), in: "!r")
        jobs.doneHanding(id)
        jobs.receive(.failed("t", recoverable: true), in: "!r")
        #expect(jobs.jobs.first?.phase == .uploading)
        jobs.receive(.failed("t", recoverable: false), in: "!r")
        #expect(jobs.jobs.first?.phase == .failed)
    }

    @Test("a video the SDK refused outright, before the queue, is a failed job")
    func refused() throws {
        let jobs = jobs()
        let id = try #require(jobs.begin(roomID: "!r", items: [.init(isVideo: true)]))
        jobs.handed(id, accepted: false)
        jobs.doneHanding(id)
        #expect(jobs.jobs.first?.phase == .failed)
    }

    @Test("a cancelled item stops being waited for")
    func cancelled() throws {
        let jobs = jobs()
        let id = try #require(jobs.begin(roomID: "!r", items: [.init(isVideo: true), .init()]))
        jobs.handed(id, accepted: true)
        jobs.receive(.created("video"), in: "!r")
        jobs.handed(id, accepted: true)
        jobs.receive(.created("photo"), in: "!r")
        jobs.doneHanding(id)
        jobs.receive(.sent("video"), in: "!r")
        jobs.receive(.cancelled("photo"), in: "!r")
        #expect(jobs.jobs.first?.phase == .sent)
        #expect(jobs.jobs.first?.what == .media(2))
    }

    @Test("the change callback fires as a job moves")
    func callback() throws {
        let jobs = jobs()
        var calls = 0
        jobs.onChange = { calls += 1 }
        let id = jobs.begin(roomID: "!r", items: [.init(isVideo: true)])
        jobs.handed(id, accepted: true)
        #expect(calls == 2)
    }
}

/// A share the system cut short by killing the app — see `LiveLocationSharer.resume`.
@Suite("Live location across launches")
@MainActor
struct LiveLocationResumeTests {
    @Test("what has not ended is carried on; what ended while the app was dead is not")
    func resume() async throws {
        let suite = "iskra.tests.liveLocationResume"
        let store = try #require(UserDefaults(suiteName: suite))
        store.removePersistentDomain(forName: suite)
        let now = Date()
        store.set(["!live": now.addingTimeInterval(600).timeIntervalSinceReferenceDate,
                   "!over": now.addingTimeInterval(-60).timeIntervalSinceReferenceDate],
                  forKey: LiveLocationSharer.storeKey("acc"))

        let sharer = LiveLocationSharer(accountID: "acc", store: store) { _ in nil }
        sharer.authorize = { true }
        await sharer.resume(now: now)
        #expect(Array(sharer.shares.keys) == ["!live"])
        // And what is written down now is only what is live.
        let stored = store.dictionary(forKey: LiveLocationSharer.storeKey("acc")) as? [String: Double]
        #expect(stored.map { Array($0.keys) } == ["!live"])
        await sharer.stopAll()
        #expect(store.dictionary(forKey: LiveLocationSharer.storeKey("acc")) == nil)
    }

    @Test("with location taken away since, nothing is resumed and nothing is kept")
    func resumeDenied() async throws {
        let suite = "iskra.tests.liveLocationResumeDenied"
        let store = try #require(UserDefaults(suiteName: suite))
        store.removePersistentDomain(forName: suite)
        store.set(["!live": Date().addingTimeInterval(600).timeIntervalSinceReferenceDate],
                  forKey: LiveLocationSharer.storeKey("acc"))

        let sharer = LiveLocationSharer(accountID: "acc", store: store) { _ in nil }
        sharer.authorize = { false }
        await sharer.resume()
        #expect(sharer.shares.isEmpty)
        #expect(store.dictionary(forKey: LiveLocationSharer.storeKey("acc")) == nil)
    }

    @Test("the demo writes nothing down")
    func demoKeepsNothing() async throws {
        let suite = "iskra.tests.liveLocationDemo"
        let store = try #require(UserDefaults(suiteName: suite))
        store.removePersistentDomain(forName: suite)
        let sharer = LiveLocationSharer(accountID: nil, store: store) { _ in nil }
        await sharer.resume()
        #expect(store.dictionaryRepresentation().keys.allSatisfy { !$0.hasPrefix("liveLocation.") })
    }
}
