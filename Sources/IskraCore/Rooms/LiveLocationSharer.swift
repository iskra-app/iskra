import CoreLocation
import Foundation
import MatrixRustSDK

/// Sharing where you are, as you move, for a while — Telegram's live location, Matrix's MSC3489.
///
/// A share is two things on the server: a `beacon_info` that says "this person is sharing, until
/// then" (`startLiveLocationShare`), and a stream of `beacon` points under it
/// (`sendLiveLocation`). The SDK draws the pair as one message whose map moves; this is the half
/// that feeds it.
///
/// One location manager for every room being shared to: the device is in one place, and three
/// chats asking for it is still one GPS. A point goes out when the person has moved far enough or
/// enough time has passed since the last one (`shouldSend`), never more often — every point is an
/// event in the room, and a walk to the shop should not be four hundred of them.
///
/// The share ends by itself when its time is up, and then the app *says* it ended
/// (`stopLiveLocationShare`) rather than leaving a beacon that only times out — the other side's
/// map stops moving in the same moment either way, but only the second one tells them why.
///
/// It keeps going in the pocket on iOS, which is the point of it: `UIBackgroundModes` has
/// `location`, and the system shows the blue pill for as long as anything is shared — the person can
/// always see that their position is leaving the phone.
@MainActor
@Observable
public final class LiveLocationSharer: NSObject {
    /// The rooms being shared to, and until when.
    public private(set) var shares: [String: Date] = [:]

    /// Set when a share could not be started or the system said no to location.
    public var failure: Failure?

    public enum Failure: String, CaseIterable, ActionFailure {
        case start
        case denied
        /// The room was not told the share ended — the others may see it as live until it runs out.
        case stop
        public var id: String { rawValue }
        public var explanation: LocalizedStringResource {
            switch self {
            case .start: CoreStrings.LiveLocation.startFailed
            case .denied: CoreStrings.LiveLocation.denied
            case .stop: CoreStrings.LiveLocation.stopFailed
            }
        }
    }

    public func isSharing(in roomID: String, now: Date = .now) -> Bool {
        shares[roomID].map { $0 > now } ?? false
    }

    private let roomFor: (String) -> Room?
    @ObservationIgnored private var manager: CLLocationManager?
    @ObservationIgnored private var lastSent: [String: (location: CLLocation, at: Date)] = [:]
    @ObservationIgnored private var latest: CLLocation?
    @ObservationIgnored private var expiry: Task<Void, Never>?

    /// Stands in for asking the system — for `DemoBackendTests`, which run in a process that may
    /// not ask anybody anything.
    @ObservationIgnored var authorize: (() async -> Bool)?

    init(roomFor: @escaping (String) -> Room?) {
        self.roomFor = roomFor
    }

    private func askForLocation() async -> Bool {
        let manager = ensureManager()
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
            // The answer arrives through the delegate; give the person the time to read the question.
            for _ in 0..<60 where manager.authorizationStatus == .notDetermined {
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        return Self.isAllowed(manager.authorizationStatus)
    }

    /// Starts sharing to a room for `duration`. Asks for location the first time; a refusal ends
    /// it here and says so.
    public func start(in roomID: String, for duration: TimeInterval) async {
        guard let room = roomFor(roomID) else {
            failure = .start
            return
        }
        guard await (authorize ?? askForLocation)() else {
            failure = .denied
            return
        }
        let manager = ensureManager()

        do {
            _ = try await room.startLiveLocationShare(durationMillis: UInt64(duration * 1000))
        } catch {
            Log.rooms.error("live location share refused: \(Log.describe(error), privacy: .public)")
            failure = .start
            return
        }
        shares[roomID] = Date.now.addingTimeInterval(duration)
        lastSent[roomID] = nil
        manager.startUpdatingLocation()
        // Something to show at once, rather than a map waiting on the next movement.
        if let latest { await send(latest, to: roomID, force: true) }
        scheduleExpiry()
    }

    /// Stops sharing to a room — the person pressed stop, or the time ran out.
    ///
    /// Two halves, and they fail differently. No more points go the moment this is called — the
    /// share is off the list before anything is awaited, so a stop the server is slow to hear never
    /// means one more position leaving the phone. Telling the *room* it stopped is the half that can
    /// fail, and it used to fail silently: the share was gone from here, the person saw it end, and
    /// everybody else's map went on saying "live" until the timeout. So it is tried again, and a stop
    /// that still did not go through is said out loud (`Failure.stop`).
    public func stop(in roomID: String, retries: Int = 2) async {
        guard shares.removeValue(forKey: roomID) != nil else { return }
        lastSent[roomID] = nil
        if shares.isEmpty { manager?.stopUpdatingLocation() }
        scheduleExpiry()

        var delay: Duration = .seconds(1)
        for attempt in 0...retries {
            if attempt > 0 {
                try? await Task.sleep(for: delay)
                delay *= 3
            }
            guard let room = roomFor(roomID) else { break }
            do {
                try await room.stopLiveLocationShare()
                return
            } catch {
                Log.rooms.error("live location stop refused (attempt \(attempt + 1, privacy: .public)): \(Log.describe(error), privacy: .public)")
            }
        }
        failure = .stop
    }

    /// Every share, for a session being closed: nothing should go on sending through a client
    /// that is going away.
    public func stopAll() async {
        // Once each: the session is closing and will not wait out a retry.
        for roomID in Array(shares.keys) { await stop(in: roomID, retries: 0) }
        expiry?.cancel()
        expiry = nil
    }

    // MARK: - Points

    /// Far enough, or long enough, since the last point sent to that room.
    nonisolated static func shouldSend(_ location: CLLocation, after last: (location: CLLocation, at: Date)?,
                                       now: Date = .now) -> Bool {
        guard let last else { return true }
        return location.distance(from: last.location) >= minimumDistance
            || now.timeIntervalSince(last.at) >= maximumSilence
    }

    nonisolated static let minimumDistance: CLLocationDistance = 30
    nonisolated static let maximumSilence: TimeInterval = 60
    /// And never closer together than this, however fast somebody is going.
    nonisolated static let minimumInterval: TimeInterval = 15

    private func received(_ location: CLLocation) async {
        latest = location
        for roomID in Array(shares.keys) {
            await send(location, to: roomID, force: false)
        }
    }

    private func send(_ location: CLLocation, to roomID: String, force: Bool) async {
        guard isSharing(in: roomID) else { return }
        let last = lastSent[roomID]
        if !force {
            if let last, Date.now.timeIntervalSince(last.at) < Self.minimumInterval { return }
            guard Self.shouldSend(location, after: last) else { return }
        }
        guard let room = roomFor(roomID) else { return }
        lastSent[roomID] = (location, .now)
        let point = Location(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
        do {
            try await room.sendLiveLocation(geoUri: point.geoURI)
        } catch {
            Log.rooms.error("a live location point was refused: \(Log.describe(error), privacy: .public)")
        }
    }

    /// One timer for the nearest end, re-armed whenever the shares change.
    private func scheduleExpiry() {
        expiry?.cancel()
        guard let next = shares.values.min() else {
            expiry = nil
            return
        }
        expiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, next.timeIntervalSinceNow)))
            guard let self, !Task.isCancelled else { return }
            for (roomID, until) in self.shares where until <= .now {
                await self.stop(in: roomID)
            }
            self.scheduleExpiry()
        }
    }

    private func ensureManager() -> CLLocationManager {
        if let manager { return manager }
        let manager = CLLocationManager()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.distanceFilter = 10
        #if os(iOS)
        // Only with the background mode declared — setting this without it is a crash, and the
        // extensions that link this target declare nothing.
        let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] ?? []
        if modes.contains("location") {
            manager.allowsBackgroundLocationUpdates = true
            manager.showsBackgroundLocationIndicator = true
            manager.pausesLocationUpdatesAutomatically = false
        }
        #endif
        self.manager = manager
        return manager
    }

    private static func isAllowed(_ status: CLAuthorizationStatus) -> Bool {
        #if os(iOS)
        status == .authorizedWhenInUse || status == .authorizedAlways
        #else
        status == .authorizedAlways || status == .authorized
        #endif
    }
}

extension LiveLocationSharer: CLLocationManagerDelegate {
    nonisolated public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor [weak self] in await self?.received(location) }
    }

    nonisolated public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Log.rooms.error("location failed: \(Log.describe(error), privacy: .public)")
    }
}
