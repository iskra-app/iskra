import Foundation
import Observation
import MatrixRustSDK

/// Photos, videos and files on their way up — followed from the moment "send" is pressed until the
/// server has every one of them, wherever the person has gone in the meantime.
///
/// It is the session's and not a room's on purpose. A `TimelineStore` lives as long as its screen,
/// and somebody who sends a two-minute video and goes back to the chat list has not stopped caring
/// whether it went. So this subscribes to the room's send queue on its own
/// (`Room.subscribeToSendQueueUpdates`), for as long as something is being sent there, and what it
/// knows is what the Live Activity and the system's background-task indicator are drawn from.
///
/// A *job* is one press of "send": a video, an album of photos, a big file. What the SDK knows about
/// is transactions — one per event — so the job is the set of transactions the queue announced
/// (`newLocalEvent`) while our sends were being handed to it. That is the fragile seam of the whole
/// thing, and the rule is kept simple to keep it honest: the next transactions to appear in that
/// room, up to the number of sends that were accepted, are the job's.
///
/// Two phases, because a job spends real time before a single byte leaves: a video is compressed
/// and stripped first (`MediaPreparation`), and a bar that sits on zero for half a minute looks
/// exactly like a bar that is stuck. Preparation is the first ~30%, the upload the rest.
///
/// Not everything is a job. One photo goes up before anybody could look at a progress bar — it is
/// followed only when it is worth following (`isWorthFollowing`).
@MainActor
@Observable
public final class MediaSendJobs {
    public struct Job: Identifiable, Sendable, Equatable {
        public let id: UUID
        public let roomID: String
        public let roomName: String
        public let avatarSeed: String
        /// A picture in `DirectoryFaces.folder()`, if the room has one there.
        public let faceFile: String?
        public let what: What
        public fileprivate(set) var phase: Phase = .preparing
        public fileprivate(set) var startedAt: Date

        /// How many sends the job was started with, and how many have been handed to the queue
        /// (accepted or not) so far.
        fileprivate var expected: Int
        fileprivate var handed = 0
        fileprivate var accepted = 0
        fileprivate var handingDone = false
        /// The queue's transactions that are this job's, and how far each has got (0...1).
        fileprivate var uploads: [String: Double] = [:]
        fileprivate var sent: Set<String> = []

        /// All of it, 0...1: preparation weighs `preparationShare`, the upload the rest.
        public var progress: Double {
            guard expected > 0 else { return 1 }
            let prepared = Double(handed) / Double(expected)
            let uploaded = uploads.values.reduce(0, +) / Double(max(accepted, 1))
            let share = MediaSendJobs.preparationShare
            return min(1, share * prepared + (1 - share) * (handingDone && accepted == 0 ? 1 : uploaded))
        }

        public var isFinished: Bool { phase == .sent || phase == .failed }
    }

    /// What is going, in the words the indicator uses: "video", "5 photos", "file".
    public enum What: Sendable, Equatable, Hashable, Codable {
        case video
        case photos(Int)
        case file
        /// Photos and videos together — an album with a clip in it.
        case media(Int)
    }

    public enum Phase: String, Sendable, Equatable, Hashable, Codable {
        /// Being compressed and stripped, before the queue has it.
        case preparing
        /// In the queue, going up.
        case uploading
        /// Everything is on the server.
        case sent
        /// The queue gave up on something, for good — "Not sent", with the chat a tap away.
        case failed
    }

    /// One thing about to be sent, as far as deciding whether to follow it goes.
    public struct Item: Sendable {
        public let isVideo: Bool
        public let isFile: Bool
        public let bytes: Int

        public init(isVideo: Bool = false, isFile: Bool = false, bytes: Int = 0) {
            self.isVideo = isVideo
            self.isFile = isFile
            self.bytes = bytes
        }
    }

    /// A video, three pictures or more, or a file over ~10 MB. Below that it is gone before an
    /// indicator could say anything.
    public nonisolated static func isWorthFollowing(_ items: [Item]) -> Bool {
        items.contains(where: \.isVideo)
            || items.count >= 3
            || items.contains { $0.bytes > bigFile }
    }

    public nonisolated static let bigFile = 10 * 1024 * 1024
    public nonisolated static let preparationShare = 0.3

    public private(set) var jobs: [Job] = [] {
        didSet { if jobs != oldValue { onChange?() } }
    }

    /// Called whenever a job moves — set by the app, which keeps the background task and the Live
    /// Activity in step with it. A callback rather than observation, because this has to go on
    /// with no view on screen to do the observing: that is the case it exists for.
    @ObservationIgnored public var onChange: (@MainActor () -> Void)?

    /// What the queue said, in this file's own words — so the bookkeeping can be tested without a
    /// Rust room behind it.
    enum QueueEvent: Sendable, Equatable {
        case created(String)
        case progress(String, Double)
        case sent(String)
        case failed(String, recoverable: Bool)
        case cancelled(String)
    }

    /// Who a room is and what it looks like, for the indicator — from the session's room list.
    public struct RoomLook: Sendable {
        public let name: String
        public let avatarSeed: String
        public let faceFile: String?

        public init(name: String, avatarSeed: String, faceFile: String?) {
            self.name = name
            self.avatarSeed = avatarSeed
            self.faceFile = faceFile
        }
    }

    @ObservationIgnored private let roomFor: (String) -> Room?
    @ObservationIgnored var look: (String) -> RoomLook?
    @ObservationIgnored private var subscriptions: [String: TaskHandle] = [:]
    @ObservationIgnored private var cleanup: [UUID: Task<Void, Never>] = [:]

    init(roomFor: @escaping (String) -> Room?, look: @escaping (String) -> RoomLook? = { _ in nil }) {
        self.roomFor = roomFor
        self.look = look
    }

    // MARK: - Starting and handing over

    /// Starts following a send of `items` into a room — or does nothing and returns nil when it is
    /// not worth following. Call before the first item is prepared, so the preparation shows.
    public func begin(roomID: String, items: [Item], now: Date = .now) -> UUID? {
        guard Self.isWorthFollowing(items) else { return nil }
        let look = look(roomID)
        let videos = items.filter(\.isVideo).count
        let what: What
        if items.count == 1 {
            what = videos == 1 ? .video : items[0].isFile ? .file : .photos(1)
        } else if videos == 0 {
            what = items.allSatisfy(\.isFile) ? .file : .photos(items.count)
        } else {
            what = .media(items.count)
        }
        let job = Job(id: UUID(), roomID: roomID,
                      roomName: look?.name ?? "",
                      avatarSeed: look?.avatarSeed ?? roomID,
                      faceFile: look?.faceFile,
                      what: what,
                      startedAt: now,
                      expected: items.count)
        jobs.append(job)
        subscribe(to: roomID)
        return job.id
    }

    /// One item has been handed to the queue — `accepted` false when the SDK refused it outright,
    /// in which case there is no transaction to wait for.
    public func handed(_ id: UUID?, accepted: Bool) {
        update(id) { job in
            job.handed += 1
            if accepted { job.accepted += 1 }
        }
    }

    /// Every item has been handed over; what is left is the queue's.
    public func doneHanding(_ id: UUID?) {
        update(id) { job in
            job.handingDone = true
            job.handed = job.expected
        }
    }

    // MARK: - The queue

    func receive(_ event: QueueEvent, in roomID: String) {
        switch event {
        case let .created(transaction):
            // The oldest job in this room that is still owed a transaction takes it.
            guard let index = jobs.firstIndex(where: {
                $0.roomID == roomID && !$0.isFinished
                    && $0.uploads.count < ($0.handingDone ? $0.accepted : max($0.accepted, $0.handed + 1))
            }) else { return }
            jobs[index].uploads[transaction] = 0
            jobs[index].phase = .uploading
        case let .progress(transaction, fraction):
            withJob(owning: transaction) { $0.uploads[transaction] = min(max(fraction, 0), 0.99) }
        case let .sent(transaction):
            withJob(owning: transaction) { job in
                job.uploads[transaction] = 1
                job.sent.insert(transaction)
            }
        case let .failed(transaction, recoverable):
            // A recoverable error is the queue pausing for the network, and it will go on by
            // itself (`SendQueueRecovery`); only a final refusal is a failure to show.
            guard !recoverable else { return }
            withJob(owning: transaction) { $0.phase = .failed }
        case let .cancelled(transaction):
            withJob(owning: transaction) { job in
                job.uploads[transaction] = nil
                job.accepted = max(0, job.accepted - 1)
            }
        }
    }

    private func withJob(owning transaction: String, _ change: (inout Job) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.uploads[transaction] != nil }) else { return }
        change(&jobs[index])
        settle(index)
    }

    private func update(_ id: UUID?, _ change: (inout Job) -> Void) {
        guard let id, let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&jobs[index])
        settle(index)
    }

    /// Finished when every accepted item is on the server — or when nothing was accepted at all,
    /// which is a failure the room screen has already put into words.
    private func settle(_ index: Int) {
        var job = jobs[index]
        if job.phase != .failed, job.handingDone {
            if job.accepted == 0 {
                job.phase = .failed
            } else if job.sent.count >= job.accepted {
                job.phase = .sent
            }
        }
        jobs[index] = job
        if job.isFinished { scheduleRemoval(of: job) }
    }

    /// A finished job stays a few seconds — long enough for "Sent" or "Not sent" to be read — and
    /// then goes, and the room stops being listened to when nothing is left in it.
    private func scheduleRemoval(of job: Job) {
        guard cleanup[job.id] == nil else { return }
        let linger: Duration = job.phase == .sent ? Self.sentLingers : Self.failedLingers
        cleanup[job.id] = Task { [weak self] in
            try? await Task.sleep(for: linger)
            guard let self else { return }
            self.jobs.removeAll { $0.id == job.id }
            self.cleanup[job.id] = nil
            if !self.jobs.contains(where: { $0.roomID == job.roomID }) {
                self.subscriptions.removeValue(forKey: job.roomID)?.cancel()
            }
        }
    }

    nonisolated static let sentLingers: Duration = .seconds(4)
    nonisolated static let failedLingers: Duration = .seconds(30)

    private func subscribe(to roomID: String) {
        guard subscriptions[roomID] == nil, let room = roomFor(roomID) else { return }
        // A placeholder handle is not possible, so the gap between asking and getting is covered by
        // checking again once the handle arrives.
        let listener = JobQueueListener { [weak self] update in
            guard let event = Self.event(from: update) else { return }
            Task { @MainActor [weak self] in self?.receive(event, in: roomID) }
        }
        Task { [weak self] in
            guard let handle = try? await room.subscribeToSendQueueUpdates(listener: listener) else { return }
            guard let self, self.subscriptions[roomID] == nil,
                  self.jobs.contains(where: { $0.roomID == roomID }) else {
                handle.cancel()
                return
            }
            self.subscriptions[roomID] = handle
        }
    }

    nonisolated static func event(from update: RoomSendQueueUpdate) -> QueueEvent? {
        switch update {
        case let .newLocalEvent(transaction): .created(transaction)
        case let .mediaUpload(transaction, _, _, progress):
            progress.total > 0 ? .progress(transaction, Double(progress.current) / Double(progress.total)) : nil
        case let .sentEvent(transaction, _): .sent(transaction)
        case let .sendError(transaction, _, recoverable): .failed(transaction, recoverable: recoverable)
        case let .cancelledLocalEvent(transaction): .cancelled(transaction)
        case .replacedLocalEvent, .retryEvent: nil
        }
    }

    /// Everything, for a session going away.
    func stop() {
        for handle in subscriptions.values { handle.cancel() }
        subscriptions = [:]
        for task in cleanup.values { task.cancel() }
        cleanup = [:]
        jobs = []
    }
}

private final class JobQueueListener: SendQueueListener {
    private let onUpdate: @Sendable (RoomSendQueueUpdate) -> Void

    init(onUpdate: @escaping @Sendable (RoomSendQueueUpdate) -> Void) {
        self.onUpdate = onUpdate
    }

    func onUpdate(update: RoomSendQueueUpdate) {
        onUpdate(update)
    }
}
