import Foundation
import Observation
import MatrixRustSDK

/// The signed-in user, and everything hanging off them.
///
/// This is what the app holds once sign-in succeeds. It owns the `Client` so that
/// nothing above `IskraCore` ever touches the SDK directly.
@MainActor
@Observable
public final class UserSession {
    public let userID: String
    public let roomList: RoomListStore
    public let search: SearchStore

    /// Who the user has blocked. Owned by the session, not made on demand, because the block list is
    /// account-wide: a settings screen manages it, a member row adds to it, and a live subscription
    /// keeps it in step — none of which can wait for one screen to be open. See `BlockStore`.
    public let blocked: BlockStore

    /// Proving devices are yours, in both directions — see `VerificationStore`.
    ///
    /// Owned by the session and not made on demand like the stores below it, and the difference is
    /// not tidiness. Verification is the one thing here that the *other* side can start: a new
    /// phone signing in asks this device to vouch for it, and that request arrives whenever it
    /// arrives — while the user is reading a chat, or scrolling the room list, or nowhere near
    /// settings. A store built by the encryption screen would have its delegate registered only
    /// while the encryption screen was open, and every request that came at any other moment would
    /// land on nobody at all.
    public let verification: VerificationStore

    /// Whether this account's history survives this device — see `RecoveryStore`.
    ///
    /// Owned here, like `verification` and for the same reason, though it took a second look to see
    /// it. It used to be `recovery()`, a factory, and the store lived exactly as long as the
    /// encryption screen that built it — which was fine while that screen was the only thing that
    /// cared. It is not any more: the room list carries a banner for a recovery code that was never
    /// saved, and a banner cannot ask a question that only settings knows the answer to. State that
    /// is needed everywhere cannot belong to one screen.
    public let recovery: RecoveryStore

    /// What the user calls themselves, for the toolbar avatar and the settings screen.
    ///
    /// Starts as the local part of the Matrix ID — "@boris:matrix.org" reads as
    /// "boris" — because that is knowable without asking the server, and a screen that
    /// shows a name immediately is better than one that shows a blank while a request
    /// is in flight. `start()` then replaces it with the real display name if there is
    /// one.
    public private(set) var displayName: String
    public private(set) var avatarURL: String?

    /// The name of *this* device, as the rest of the account sees it — and the only true
    /// thing the encryption screen can say about sessions, since the others cannot be
    /// reached at all (see `ROADMAP.md`, stage 6).
    ///
    /// Resolved once, here, exactly like `userID`: it is fixed for the life of the client,
    /// and asking the SDK again on every read would cross the FFI boundary to be told the
    /// same thing. Optional rather than `?? ""`, because a device with no ID is a thing the
    /// screen should decline to talk about rather than a blank line under a heading.
    public let deviceID: String?

    /// Internal rather than private, because `RoomCreation` is an extension in another
    /// file and needs it. The rule it is kept under is unchanged: the `Client` does not
    /// leave `IskraCore`, and nothing above this layer holds one.
    let client: Client
    private let authentication: AuthenticationService

    /// What the connection is doing right now: direct, or through the local listener.
    ///
    /// Forwarded rather than exposing the service itself — the settings screen needs this one
    /// answer, not the ability to sign anybody in.
    public func tunnelStatus() async -> TunnelStatus {
        await authentication.tunnelStatus()
    }

    public init(client: Client, authentication: AuthenticationService) {
        self.client = client
        self.authentication = authentication
        let userID = (try? client.userId()) ?? ""
        self.userID = userID
        self.deviceID = try? client.deviceId()
        self.displayName = Self.localPart(of: userID)
        self.roomList = RoomListStore(client: client)
        self.search = SearchStore(client: client)
        self.blocked = BlockStore(client: client)
        self.verification = VerificationStore(client: client, ownUserID: userID)
        self.recovery = RecoveryStore(encryption: client.encryption())
    }

    /// The server has stopped accepting this session, and nobody on this device asked it to.
    ///
    /// Somebody ended the session from another client, or an administrator deactivated the
    /// account. Until this existed the app simply *did not find out*: sync began failing, the room
    /// list froze on whatever was in the cache, messages went into the send queue and stayed
    /// there, and every screen went on looking exactly as it had. The only symptom was an app that
    /// had quietly stopped being connected to anything, and the only cure was to guess as much and
    /// sign out by hand.
    ///
    /// Read by `IskraRootView`, which takes the app back to the sign-in screen and says why.
    public private(set) var wasEndedElsewhere = false

    /// Kept alive because dropping it unsubscribes. Cancelled in `signOut()`.
    private var authErrorHandle: TaskHandle?

    /// The timelines this session has handed out and that are still on screen, by room.
    ///
    /// It does two jobs, and it is worth being explicit that they are two, because either alone
    /// would have justified it.
    ///
    /// **It is how sign-out reaches them.** Signing out ends with `logout()`, which deletes the
    /// encrypted SQLite store from the disk. Anything still subscribed to it at that moment —
    /// `addListener`, `subscribeToRoomInfoUpdates`, `subscribeToSendQueueUpdates`,
    /// `subscribeToTypingNotifications` — is a live listener over a file that no longer exists. And
    /// a room *is* still open at that moment on every platform where the app has two columns: on
    /// the Mac and on a wide iPad the conversation stays in the detail column while the user signs
    /// out from the sidebar. The room list was being stopped and nothing else was.
    ///
    /// **It is how the same room stops being two stores.** `timeline(forRoomID:)` is called from
    /// inside `IskraRootView.body`, which SwiftUI re-runs whenever anything it reads changes. Every
    /// one of those passes used to mint a fresh `TimelineStore` — an FFI call to find the room and
    /// an object thrown away microseconds later, saved from being a real bug only by `@State`
    /// holding on to the first one. Returning the live store instead makes the call idempotent,
    /// which is what the view was assuming all along.
    ///
    /// Weakly, because the screen owns the store and this is only a way to reach it. When the room
    /// closes, the box empties on its own and the next visit builds a new one.
    private var openTimelines: [String: WeakBox<TimelineStore>] = [:]

    private struct WeakBox<T: AnyObject> {
        weak var value: T?
    }

    /// Starts the sync loop. Everything else follows from this.
    public func start() async throws {
        // Before the sync loop, not after: the token can be refused by the very first request the
        // loop makes, and a delegate registered afterwards would miss it.
        authErrorHandle = try? client.setDelegate(delegate: AuthErrors { [weak self] in
            Task { @MainActor [weak self] in
                await self?.endedElsewhere()
            }
        })

        await loadProfile()

        // Before the room list, because it is the only listener in the app that has to be in place
        // for something *other people's devices* do. Everything else here is started so that this
        // device can ask a question; this is started so that it can be asked one.
        await verification.listen()

        // Not awaited on the server's behalf — `load()` reads what the SDK already knows and
        // subscribes for the rest. What it knows *now* may well be `.unknown`; the screen that
        // actually has to branch on the answer calls `waitForSetup()` and waits properly.
        recovery.load()

        // The one road from "the sync loop noticed the network" to "the room on screen noticed it
        // too". `RoomListStore` learns about the network and knows nothing about timelines; the
        // timelines are stranded and know nothing about the network. This is the only object that
        // holds both, so it is the only place the two can be introduced.
        roomList.onConnectivityChange = { [weak self] offline in
            await self?.connectivityChanged(offline: offline)
        }

        try await roomList.start()
    }

    /// Passes the news to every room that is open. See `TimelineStore.connectivityChanged`, which is
    /// what a room does with it: unstick the history that failed to load while the network was gone.
    private func connectivityChanged(offline: Bool) async {
        for box in openTimelines.values {
            await box.value?.connectivityChanged(offline: offline)
        }
    }

    /// Tears the session down locally, without asking the server for permission it has already
    /// withdrawn. See `wasEndedElsewhere`.
    private func endedElsewhere() async {
        guard !wasEndedElsewhere else { return }
        wasEndedElsewhere = true

        Log.session.error("the server no longer accepts this session; signing out locally")

        await stopEverything()

        authErrorHandle?.cancel()
        authErrorHandle = nil

        // Not `signOut()`: that one asks the server to forget the device, and the server has
        // already forgotten it. The local half — keys, tokens, the encrypted store — happens
        // exactly as it would have.
        await authentication.forgetSession()
    }

    /// The user's own name and picture. Failing to fetch either is not an error worth
    /// surfacing: the Matrix ID is already a usable name, and initials are already a
    /// usable avatar.
    private func loadProfile() async {
        if let name = try? await client.displayName(), !name.isEmpty {
            displayName = name
        }
        avatarURL = try? await client.avatarUrl()
    }

    /// "@boris:matrix.org" → "boris".
    private static func localPart(of userID: String) -> String {
        let withoutSigil = userID.hasPrefix("@") ? String(userID.dropFirst()) : userID
        return String(withoutSigil.prefix { $0 != ":" })
    }

    /// A timeline for one room, or nil if this account is not in it.
    ///
    /// The room list is asked first and the client second, and the second question is not
    /// redundant: a room the user has *just created* exists on the server and in the SDK's
    /// store before the room-list stream has caught up with it, and for that half-second
    /// the list would answer "no such room" about a room whose screen we are opening. See
    /// `createRoom`, which selects it the moment it exists.
    ///
    /// The user's own ID goes down with it because the timeline has to be able to tell a
    /// reaction the user left from one they merely received — see `MessageReaction`.
    public func timeline(forRoomID roomID: String) -> TimelineStore? {
        // The one that is already open, if this room is the one on screen. See `openTimelines`.
        if let open = openTimelines[roomID]?.value { return open }

        guard let room = roomList.room(withID: roomID) ?? (try? client.getRoom(roomId: roomID)) else {
            return nil
        }

        let store = TimelineStore(room: room, ownUserID: userID)

        // The empty boxes go on the way past. There is no timer and no bookkeeping: a box is added
        // only when a room is opened, and nobody opens enough rooms in one sitting for the sweep to
        // be worth thinking about.
        openTimelines = openTimelines.filter { $0.value.value != nil }
        openTimelines[roomID] = WeakBox(value: store)

        return store
    }

    /// Everything the room-info screen needs, built only when it is opened.
    ///
    /// Made here rather than by `TimelineStore`, which is where it used to come from, for
    /// one reason: notification settings hang off the *account*, not off the room, so this
    /// store needs the `Client` — and the client is the session's to lend. A timeline has
    /// no business holding one.
    public func details(forRoomID roomID: String) -> RoomDetailsStore? {
        guard let room = roomList.room(withID: roomID) ?? (try? client.getRoom(roomId: roomID)) else {
            return nil
        }
        return RoomDetailsStore(room: room, ownUserID: userID, client: client)
    }

    /// The rooms inside a space, made when its screen is opened. A space is reached by its own room
    /// ID, and the store pages the SDK's space service for what is in it — see `SpaceStore`.
    public func space(forRoomID roomID: String) -> SpaceStore {
        SpaceStore(client: client, spaceID: roomID)
    }

    /// Searching within one conversation, made when its search is opened. Separate from the global
    /// `search` store: this one runs the room-scoped `Room.searchMessages`, so it needs the room
    /// handle the same way a timeline does.
    public func roomSearch(forRoomID roomID: String) -> RoomSearchStore? {
        guard let room = roomList.room(withID: roomID) ?? (try? client.getRoom(roomId: roomID)) else {
            return nil
        }
        return RoomSearchStore(room: room)
    }

    /// Forwards a message into another room. Opens (or reuses) the destination's timeline just long
    /// enough to send — `start()` is idempotent, and the message goes into the SDK's own persistent
    /// send queue, so it leaves even if the timeline is let go the moment after. Returns whether the
    /// send was dispatched; `false` only when the destination room could not be reached at all.
    public func forward(_ message: Message, toRoomID roomID: String) async -> Bool {
        guard let target = timeline(forRoomID: roomID) else { return false }
        do {
            try await target.start()
        } catch {
            return false
        }
        await target.forward(message, loader: media())
        return true
    }

    /// Sends a plain-text message into a room by ID — for flushing the App-Intents outbox when the
    /// app comes up. Opens the destination timeline just long enough to send (`start()` is
    /// idempotent, the message goes into the persistent send queue). Returns whether it dispatched.
    @discardableResult
    public func sendText(_ text: String, toRoomID roomID: String) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let target = timeline(forRoomID: roomID) else { return false }
        do {
            try await target.start()
        } catch {
            return false
        }
        await target.send(text: trimmed)
        return true
    }

    /// Fetches media bytes (a photo, a voice message) on demand.
    public func media() -> MediaLoader {
        MediaLoader(client: client)
    }

    /// Where the user manages the devices they are signed in on — on the server's own web page.
    ///
    /// There is no native list, and there is not going to be one. The Rust SDK has `devices()` and
    /// `delete_devices()`; the FFI deliberately does not export either, and on a homeserver running
    /// the authentication service `DELETE /_matrix/client/v3/devices/{id}` answers 404 — the endpoint
    /// is gone, not merely guarded. Writing our own HTTP client over the access token, which is the
    /// workaround this looks like it wants, would reach a door that is bricked up.
    ///
    /// What the FFI *does* hand over is the address of the page that can do it, with the session the
    /// user already has. `.devicesList` rather than `.profile`: if the SDK will point us at the exact
    /// page, arriving one click away from it would be a small, pointless discourtesy.
    ///
    /// `nil` when the session was not obtained through OAuth — the metadata this is built from simply
    /// does not exist then — and the screen above answers that by not offering the row at all.
    public func deviceManagementURL() async -> URL? {
        do {
            guard let address = try await client.accountUrl(action: .devicesList) else {
                // Not an error: an account signed in the old way has no such page, and the row simply
                // is not offered. Logged all the same, because "the row is missing" and "the row is
                // missing *and nobody knows why*" are different bugs to be holding.
                Log.session.info("this server has no page for managing devices")
                return nil
            }
            return URL(string: address)
        } catch {
            Log.session.error("could not find where devices are managed: \(Log.describe(error), privacy: .public)")
            return nil
        }
    }

    /// Telling the homeserver where to send a push. See `PushRegistration` — and note that the
    /// gateway it needs does not exist yet, which is the one piece of this app that is genuinely
    /// waiting on something outside Xcode.
    public func pushes() -> PushRegistration {
        PushRegistration(client: client)
    }

    /// What this account is keeping on the device, built when the screen that shows it is opened.
    ///
    /// It takes the room list with it, and not for the rooms: clearing the cache means taking the
    /// sync service down and bringing it back up, and the room list is the only thing that holds
    /// one.
    public func storage() -> StorageStore {
        StorageStore(client: client, roomList: roomList, locations: authentication.storageURLs())
    }

    // MARK: - Changing who you are

    /// The name everyone else sees. Applied at once and put back if the server refuses —
    /// the same optimism as `RoomDetailsStore.rename`, and for the same reason: this is a
    /// field the user is looking straight at, and a name that flickers back a second later
    /// is a clearer report of failure than a name that never moved.
    ///
    /// An empty name is refused rather than sent. Matrix allows it, and the result is a
    /// user whose messages are signed with a bare Matrix ID — which is not a name people
    /// choose, it is one they end up with by deleting the field and tapping away.
    ///
    /// These three *throw* rather than parking the refusal in a `failure` field on the
    /// session, which is what they used to do. The session is the app-lifetime object every
    /// screen holds; a settings alert's dismiss state has no business living in it, and the
    /// field was public and settable, so a view could — and did — write a photo-library
    /// error into the model layer. Reporting failure as a typed throw is what `RoomCreation`
    /// already does, and it leaves the alert where the alert belongs.
    public func rename(to newName: String) async throws(AccountActionFailure) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != displayName else { return }

        let previous = displayName
        displayName = trimmed

        do {
            try await client.setDisplayName(name: trimmed)
        } catch {
            Log.session.error("the name would not change: \(Log.describe(error), privacy: .public)")
            displayName = previous
            throw .name
        }
    }

    /// The picture, as bytes, exactly as a room's picture goes up — see
    /// `RoomDetailsStore.setPicture` for why it is bytes and not a path on disk.
    public func setPicture(_ data: Data, filename: String) async throws(AccountActionFailure) {
        let info = MediaMetadata.image(data: data, filename: filename)

        do {
            try await client.uploadAvatar(mimeType: info.mimeType, data: data)
            avatarURL = try? await client.avatarUrl()
        } catch {
            Log.session.error("the picture would not change: \(Log.describe(error), privacy: .public)")
            throw .picture
        }
    }

    public func removePicture() async throws(AccountActionFailure) {
        let previous = avatarURL
        avatarURL = nil

        do {
            try await client.removeAvatar()
        } catch {
            Log.session.error("the picture would not clear: \(Log.describe(error), privacy: .public)")
            avatarURL = previous
            throw .picture
        }
    }

    public func signOut() async {
        authErrorHandle?.cancel()
        authErrorHandle = nil

        // Before `signOut`, which ends in `logout()`, which deletes the encrypted store off the
        // disk. Every listener still registered at that moment is a listener over a file that has
        // been unlinked underneath it. See `openTimelines`.
        await stopEverything()

        await authentication.signOut(client: client)
    }

    /// The app has gone into the user's pocket, or come back out of it.
    ///
    /// Only the sync loop is affected, and only on iOS — see `RoomListStore.pause()`, which explains
    /// why the reason is the notification extension rather than the battery.
    public func enteredBackground() async {
        await roomList.pause()
    }

    public func enteredForeground() async {
        await roomList.resume()
    }

    /// Everything this session handed out that is still listening to the SDK.
    ///
    /// Called from both ways out — the user signing out, and the server having already signed them
    /// out — because the store on the disk goes away in both, and a room left open in the detail
    /// column does not know that.
    private func stopEverything() async {
        verification.stop()
        recovery.stop()

        for box in openTimelines.values {
            box.value?.stop()
        }
        openTimelines = [:]

        // Nothing to tell any more, and nobody to tell. The closure holds `self` weakly, so this is
        // not a leak being cleaned up — it is the store being left with no reason to call into a
        // session that is on its way out.
        roomList.onConnectivityChange = nil

        await roomList.stop()
    }
}

/// The SDK telling us the server has stopped accepting our token.
///
/// `isSoftLogout` is dropped, and the distinction it draws is one this app cannot act on. A soft
/// logout means the tokens are dead but the encrypted store could be kept and re-attached to a
/// fresh sign-in by the same user — which is a real optimisation and a real screen ("sign back in
/// as Boris"), and Iskra has neither. Treating both as "you are signed out" is the honest
/// simplification: the alternative is a store kept for a flow that does not exist.
private final class AuthErrors: ClientDelegate {
    private let onAuthError: @Sendable () -> Void

    init(onAuthError: @escaping @Sendable () -> Void) {
        self.onAuthError = onAuthError
    }

    func didReceiveAuthError(isSoftLogout: Bool) {
        onAuthError()
    }

    /// The SDK's own note says an embedder that does not run background jobs may leave this empty.
    /// This one does not.
    func onBackgroundTaskErrorReport(taskName: String, error: BackgroundTaskFailureReason) {}
}
