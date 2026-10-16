#if os(iOS)
import ActivityKit
import Foundation
import IskraCore

/// The Live Activity of a live location share: on the lock screen and in the Dynamic Island for as
/// long as the share runs, with the time left and a button that stops it.
///
/// One activity for every chat being shared to — there is one GPS and one blue pill, and "stop"
/// means stop. It is moved along only when something it shows changes (a chat added or ended, the
/// first point gone, a stop the server did not hear); never once per point, which would spend
/// ActivityKit's budget on nothing anybody can see. The clock runs down on its own
/// (`Text(timerInterval:)`).
///
/// The button is `StopLiveLocationIntent`, which runs in this process and reaches the sharer through
/// `LiveLocationSharer.stopEverywhere()`; the share ending is what ends the activity, here.
@MainActor
enum LiveLocationActivity {
    /// Follows this session's sharer from now on, and tidies whatever an earlier run left on screen.
    static func attach(_ session: UserSession) {
        session.liveLocation.onChange = { [weak session] in
            guard let session else { return }
            sync(session)
        }
        sync(session)
    }

    static func sync(_ session: UserSession) {
        let account = session.sessionID
        let sharer = session.liveLocation
        let all = Activity<LiveLocationAttributes>.activities

        // Another account's share was stopped when that account was closed; its activity goes too.
        for activity in all where activity.attributes.accountID != account {
            end(activity, stopFailed: false)
        }
        let mine = all.filter { $0.attributes.accountID == account }

        guard let state = state(of: session) else {
            for activity in mine { end(activity, stopFailed: sharer.failure == .stop) }
            return
        }

        if let current = mine.first {
            for extra in mine.dropFirst() { end(extra, stopFailed: false) }
            guard current.content.state != state else { return }
            // `Activity` is not `Sendable`, and ActivityKit's own methods are what it is sent to;
            // nothing here touches it again after the hand-over.
            nonisolated(unsafe) let activity = current
            Task { await activity.update(ActivityContent(state: state, staleDate: state.until)) }
        } else {
            // Only ever succeeds with the app in front, which it is when a share is started; a
            // share resumed in the background simply goes without one until the app is opened.
            guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
            do {
                _ = try Activity.request(attributes: LiveLocationAttributes(accountID: account),
                                         content: ActivityContent(state: state, staleDate: state.until),
                                         pushType: nil)
            } catch {
                Log.rooms.error("the live location activity would not start: \(Log.describe(error), privacy: .public)")
            }
        }
    }

    /// What the activity shows, or nil when nothing is being shared.
    private static func state(of session: UserSession) -> LiveLocationAttributes.ContentState? {
        let shares = session.liveLocation.shares.filter { $0.value > .now }
        guard let until = shares.values.max() else { return nil }
        // The chat that ends last first: it is the one the clock is counting down.
        let order = shares.sorted { $0.value > $1.value }.map(\.key)
        let rooms = order.compactMap { id in session.roomList.rooms.first { $0.id == id } }
        let first = rooms.first
        // The lock screen is for anybody holding the phone. With the app lock on, the widget shows
        // nobody's name or face, and neither does this: it says a share is running and when it
        // ends, which the blue pill says anyway.
        if AppLock.isEnabled(defaults: ChatDirectory.sharedDefaults) {
            return .init(chats: [], faceFile: nil, avatarSeed: "", until: until,
                         hasSentPoint: !session.liveLocation.roomsWithPoints.isDisjoint(with: order))
        }
        return .init(chats: rooms.map(\.name),
                     faceFile: session.chatFaces.file(for: first?.avatarURL),
                     avatarSeed: first?.avatarSeed ?? order.first ?? "",
                     until: until,
                     hasSentPoint: !session.liveLocation.roomsWithPoints.isDisjoint(with: order))
    }

    /// "Sharing has ended" for a few seconds, then gone — or, when the room never heard that it
    /// ended, the warning stays a while longer, because it is the only place that says so once the
    /// app is in a pocket.
    private static func end(_ activity: Activity<LiveLocationAttributes>, stopFailed: Bool) {
        var state = activity.content.state
        guard !state.ended else { return }
        state.ended = true
        state.stopFailed = stopFailed
        let linger: TimeInterval = stopFailed ? 600 : 8
        nonisolated(unsafe) let activity = activity
        Task {
            await activity.end(ActivityContent(state: state, staleDate: nil),
                               dismissalPolicy: .after(.now.addingTimeInterval(linger)))
        }
    }
}
#endif
