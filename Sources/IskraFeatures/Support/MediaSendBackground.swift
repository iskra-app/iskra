#if os(iOS)
import ActivityKit
import BackgroundTasks
import Foundation
import IskraCore
import UIKit

/// Keeps a video, an album or a big file going after the app has been put away — and says how far
/// it has got.
///
/// Before this, a send simply stopped in a pocket: nothing asked iOS for time, so the process was
/// suspended a few seconds after the screen went dark and the upload stood still until the app was
/// next opened. An indicator would not have helped — a bar frozen at 45% is worse than none — so
/// the work comes first and the bar second.
///
/// - **iOS 26 and later: `BGContinuedProcessingTask`.** A task the person started, which the system
///   lets run on after the app is gone and draws its own progress and cancel for. A Live Activity of
///   ours on top would be a second indicator of the same thing, so there is none.
/// - **iOS 18–25: `beginBackgroundTask` and a Live Activity.** About half a minute, and when it runs
///   out first the activity says so honestly — "will carry on when you open Iskra" — because the
///   upload is still in the queue and does carry on then.
///
/// Either way nothing is lost when time runs out: the attachment stays in the SDK's send queue and
/// leaves the next time the app is open. And while the task holds the app awake the loopback
/// listener and the bridge's relays are still there, so the tunnel needs no special case.
@MainActor
final class MediaSendBackground {
    static let shared = MediaSendBackground()

    private enum Hold {
        case none
        /// Submitted; waiting for the system to hand the task over.
        case continuedPending(String)
        /// Holding a continued-processing task — a `BGContinuedProcessingTask`, kept as `AnyObject`
        /// because the type does not exist below iOS 26.
        case continued(String, AnyObject)
        case legacy(UIBackgroundTaskIdentifier)
    }

    private var hold: Hold = .none
    /// The legacy background time ran out with an upload still going.
    private var waitingForApp = false
    private var activities: [UUID: Activity<MediaSendAttributes>] = [:]
    private var lastPushed: [UUID: (at: Date, state: MediaSendAttributes.ContentState)] = [:]
    private weak var session: UserSession?

    func attach(_ session: UserSession) {
        self.session = session
        session.mediaJobs.onChange = { [weak self, weak session] in
            guard let self, let session else { return }
            self.sync(session)
        }
        sync(session)
    }

    func sync(_ session: UserSession) {
        guard session === self.session else { return }
        let jobs = session.mediaJobs.jobs
        let active = jobs.filter { !$0.isFinished }
        if UIApplication.shared.applicationState == .active { waitingForApp = false }

        if active.isEmpty {
            release(success: !jobs.contains { $0.phase == .failed })
        } else {
            acquire(for: active)
        }
        reportProgress(active)

        if usesOwnActivities {
            syncActivities(jobs, account: session.sessionID)
        }
    }

    // MARK: - Background time

    /// iOS 26's own indicator stands in for ours — unless the system would not take the task, in
    /// which case the app falls back to the older way, activity and all.
    private var usesOwnActivities: Bool {
        switch hold {
        case .continued, .continuedPending: false
        case .none, .legacy: true
        }
    }

    private func acquire(for active: [MediaSendJobs.Job]) {
        guard case .none = hold else { return }
        if #available(iOS 26, *), submitContinued(for: active) { return }
        beginLegacy()
    }

    private func beginLegacy() {
        let id = UIApplication.shared.beginBackgroundTask(withName: "Iskra media upload") { [weak self] in
            // The time is up and the upload is not. It stays in the queue; the activity says so.
            MainActor.assumeIsolated {
                guard let self else { return }
                self.waitingForApp = true
                if let session = self.session { self.syncActivities(session.mediaJobs.jobs, account: session.sessionID) }
                self.release(success: false)
            }
        }
        hold = id == .invalid ? .none : .legacy(id)
    }

    @available(iOS 26, *)
    private func submitContinued(for active: [MediaSendJobs.Job]) -> Bool {
        let identifier = "moscow.swag.iskra.upload.\(UUID().uuidString)"
        // A continued-processing task may be registered at any time — the one kind that may — and
        // each identifier once, which is why every job gets a fresh one.
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            Task { @MainActor [weak self] in self?.started(task, identifier: identifier) }
        }
        guard registered, let first = active.first else { return false }

        let request = BGContinuedProcessingTaskRequest(identifier: identifier,
                                                       title: Self.title(of: first.what),
                                                       subtitle: Self.subtitle(of: first))
        // Run now or not at all: a task queued behind others would start after the person has
        // already watched the upload stall.
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            Log.media.error("background upload task refused: \(Log.describe(error), privacy: .public)")
            return false
        }
        hold = .continuedPending(identifier)
        return true
    }

    @available(iOS 26, *)
    private func started(_ task: BGTask, identifier: String) {
        guard let task = task as? BGContinuedProcessingTask else {
            task.setTaskCompleted(success: false)
            return
        }
        guard case .continuedPending(identifier) = hold else {
            // Everything finished before the system got round to starting it.
            task.setTaskCompleted(success: true)
            return
        }
        hold = .continued(identifier, task)
        task.progress.totalUnitCount = Self.units
        task.expirationHandler = { [weak self] in
            // The system or the person ended it. The upload is still in the queue, and goes on
            // when the app is next open.
            Task { @MainActor [weak self] in
                guard let self, case .continued(identifier, _) = self.hold else { return }
                self.hold = .none
                task.setTaskCompleted(success: false)
            }
        }
        if let session { sync(session) }
    }

    private func reportProgress(_ active: [MediaSendJobs.Job]) {
        guard #available(iOS 26, *), case let .continued(_, object) = hold,
              let task = object as? BGContinuedProcessingTask, !active.isEmpty else { return }
        let progress = active.map(\.progress).reduce(0, +) / Double(active.count)
        task.progress.completedUnitCount = Int64(progress * Double(Self.units))
        if let first = active.first {
            task.updateTitle(Self.title(of: first.what), subtitle: Self.subtitle(of: first))
        }
    }

    private static let units: Int64 = 1000

    private func release(success: Bool) {
        switch hold {
        case .none:
            return
        case .continuedPending:
            break
        case let .continued(_, object):
            if #available(iOS 26, *), let task = object as? BGContinuedProcessingTask {
                task.progress.completedUnitCount = Self.units
                task.setTaskCompleted(success: success)
            }
        case let .legacy(id):
            UIApplication.shared.endBackgroundTask(id)
        }
        hold = .none
    }

    // MARK: - The Live Activity (iOS 18–25)

    private func syncActivities(_ jobs: [MediaSendJobs.Job], account: String) {
        for job in jobs {
            let state = MediaSendAttributes.ContentState(phase: phase(of: job), progress: job.progress)
            if let activity = activities[job.id] {
                if job.isFinished {
                    finish(activity, job: job, state: state)
                } else if shouldPush(state, for: job.id) {
                    lastPushed[job.id] = (.now, state)
                    // Not `Sendable`; handed to ActivityKit and not touched here again.
                    nonisolated(unsafe) let activity = activity
                    Task { await activity.update(ActivityContent(state: state, staleDate: nil)) }
                }
            } else if !job.isFinished, ActivityAuthorizationInfo().areActivitiesEnabled {
                // With the app lock on, no name and no face on a screen anybody can see — the
                // widget's rule. What is going up, and how far, is still said.
                let hidden = Self.isLocked
                let attributes = MediaSendAttributes(roomID: job.roomID, accountID: account,
                                                     roomName: hidden ? "" : job.roomName,
                                                     faceFile: hidden ? nil : job.faceFile,
                                                     avatarSeed: hidden ? "" : job.avatarSeed,
                                                     what: job.what)
                do {
                    activities[job.id] = try Activity.request(attributes: attributes,
                                                              content: ActivityContent(state: state, staleDate: nil),
                                                              pushType: nil)
                    lastPushed[job.id] = (.now, state)
                } catch {
                    // In the background, or switched off in Settings: the upload goes on regardless.
                    Log.media.error("the upload activity would not start: \(Log.describe(error), privacy: .public)")
                }
            }
        }
        // A job gone without our seeing it finish — the session closed under it.
        for (id, activity) in activities where !jobs.contains(where: { $0.id == id }) {
            nonisolated(unsafe) let activity = activity
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
            activities[id] = nil
            lastPushed[id] = nil
        }
    }

    private func phase(of job: MediaSendJobs.Job) -> MediaSendAttributes.ContentState.Phase {
        switch job.phase {
        case .sent: .sent
        case .failed: .failed
        case .preparing: waitingForApp ? .waitingForApp : .preparing
        case .uploading: waitingForApp ? .waitingForApp : .uploading
        }
    }

    /// ActivityKit has a budget: no more than once a second, and only for a visible step.
    private func shouldPush(_ state: MediaSendAttributes.ContentState, for id: UUID) -> Bool {
        guard let last = lastPushed[id] else { return true }
        if last.state.phase != state.phase { return true }
        return Date.now.timeIntervalSince(last.at) >= 1 && abs(state.progress - last.state.progress) >= 0.02
    }

    /// "Sent" for a few seconds; "Not sent" for longer, since it is the news somebody has to act on.
    private func finish(_ activity: Activity<MediaSendAttributes>, job: MediaSendJobs.Job,
                        state: MediaSendAttributes.ContentState) {
        activities[job.id] = nil
        lastPushed[job.id] = nil
        let linger: TimeInterval = job.phase == .sent ? 4 : 600
        nonisolated(unsafe) let activity = activity
        Task {
            await activity.end(ActivityContent(state: state, staleDate: nil),
                               dismissalPolicy: .after(.now.addingTimeInterval(linger)))
        }
    }

    /// The chat's name under the title — unless the app lock is on, and then nothing: the system's
    /// indicator is on the lock screen too.
    static func subtitle(of job: MediaSendJobs.Job) -> String {
        isLocked ? "" : job.roomName
    }

    private static var isLocked: Bool { AppLock.isEnabled(defaults: ChatDirectory.sharedDefaults) }

    static func title(of what: MediaSendJobs.What) -> String {
        switch what {
        case .video: String(localized: CoreStrings.LiveActivity.sendingVideo)
        case .photos(1): String(localized: CoreStrings.LiveActivity.sendingPhoto)
        case .photos, .media: String(localized: CoreStrings.LiveActivity.sendingAlbum)
        case .file: String(localized: CoreStrings.LiveActivity.sendingFile)
        }
    }
}
#endif
