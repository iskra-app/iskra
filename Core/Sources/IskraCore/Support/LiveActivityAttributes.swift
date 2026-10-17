#if canImport(ActivityKit) && os(iOS)
import ActivityKit
import Foundation

// The two Live Activities, as data. They live here and not beside the views that draw them because
// three bundles must agree on them byte for byte: the app starts and updates them, the widget
// extension draws them, and ActivityKit carries them between the two as JSON — a field renamed in
// one and not the other is an activity that silently draws nothing. This is ActivityKit and not
// SwiftUI, so `IskraCore` keeps its rule; how they look is in `Apps/Widgets`.
//
// Neither is ever updated by a push. That would mean teaching our Sygnal about ActivityKit tokens,
// and the server would then know that somebody is sharing where they are, or sending a video, right
// now. Both are started and moved along by the app itself, which is already awake for both.

/// Where you are, being shared — one activity for every chat it is going to, because there is one
/// GPS and one pill, and "stop" means stop.
public struct LiveLocationAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable, Sendable {
        /// The chats it goes to, by name.
        public var chats: [String]
        /// The first chat's face — a file in `DirectoryFaces.folder()` — and what to draw without one.
        public var faceFile: String?
        public var avatarSeed: String
        /// When the last share ends. A clock runs down to it on the lock screen without an update.
        public var until: Date
        /// Whether a point has gone out yet — until then the others see a share with no map.
        public var hasSentPoint: Bool
        /// The room was not told the share ended (`LiveLocationSharer.Failure.stop`).
        public var stopFailed: Bool
        /// It is over: by time, by the button, or because the account was closed.
        public var ended: Bool

        public init(chats: [String], faceFile: String?, avatarSeed: String, until: Date,
                    hasSentPoint: Bool, stopFailed: Bool = false, ended: Bool = false) {
            self.chats = chats
            self.faceFile = faceFile
            self.avatarSeed = avatarSeed
            self.until = until
            self.hasSentPoint = hasSentPoint
            self.stopFailed = stopFailed
            self.ended = ended
        }
    }

    /// Whose share it is — the session ID. An activity left over from a run that was killed is
    /// picked up only by the account that started it.
    public let accountID: String

    public init(accountID: String) {
        self.accountID = accountID
    }
}

/// A video, an album or a large file on its way up — on iOS 18–25 only. From iOS 26 the system draws
/// its own indicator for `BGContinuedProcessingTask`, and a second one of ours would be the same
/// thing said twice.
public struct MediaSendAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable, Sendable {
        public enum Phase: String, Codable, Hashable, Sendable {
            case preparing, uploading, sent, failed
            /// The background time ran out before the upload did. It is still in the queue and goes
            /// on the next time the app is opened — which is what the activity now says.
            case waitingForApp
        }

        public var phase: Phase
        /// 0...1, preparation included — see `MediaSendJobs.Job.progress`.
        public var progress: Double

        public init(phase: Phase, progress: Double) {
            self.phase = phase
            self.progress = progress
        }
    }

    public let roomID: String
    public let accountID: String
    public let roomName: String
    public let faceFile: String?
    public let avatarSeed: String
    public let what: MediaSendJobs.What

    public init(roomID: String, accountID: String, roomName: String, faceFile: String?,
                avatarSeed: String, what: MediaSendJobs.What) {
        self.roomID = roomID
        self.accountID = accountID
        self.roomName = roomName
        self.faceFile = faceFile
        self.avatarSeed = avatarSeed
        self.what = what
    }
}
#endif

import Foundation

public extension AppEnvironment {
    /// What a Live Activity opens when it is tapped: the app, and in it this chat of this account.
    /// The same scheme the share sheet hands over with (`shareHandoffURL`).
    static func openChatURL(roomID: String, accountID: String?) -> URL {
        var components = URLComponents()
        components.scheme = "moscow.swag.iskra"
        components.path = "/open"
        components.queryItems = [URLQueryItem(name: "room", value: roomID)]
            + (accountID.map { [URLQueryItem(name: "account", value: $0)] } ?? [])
        return components.url ?? shareHandoffURL
    }
}

public extension ChatDirectory.OpenRequest {
    /// The chat an `openChatURL` asks for, or nil for any other URL.
    init?(url: URL) {
        guard url.scheme == "moscow.swag.iskra", url.path == "/open",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let room = items.first(where: { $0.name == "room" })?.value, !room.isEmpty
        else { return nil }
        self.init(roomID: room, accountID: items.first(where: { $0.name == "account" })?.value)
    }
}
