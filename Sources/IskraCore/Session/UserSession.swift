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
    public private(set) var displayName: String {
        didSet { rememberProfile() }
    }
    public private(set) var avatarURL: String? {
        didSet { rememberProfile() }
    }

    /// Written down for the account switcher, which has to show this account's face while it is
    /// not open and there is no client to ask. Never for the demo, which is in no list.
    private func rememberProfile() {
        guard !isDemo else { return }
        authentication.rememberProfile(sessionID: sessionID, displayName: displayName, avatarURL: avatarURL)
    }

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

    /// Whether this is the made-up account on the in-process demo server — see `MockHomeserver`.
    ///
    /// It changes exactly two things, both about leaving: signing out of the demo must not sign
    /// the device out of the real account, and the demo cannot be "ended elsewhere". Everything
    /// else is the same session, which is the point of it.
    public let isDemo: Bool

    /// Where this session's stores are, when that is not what the Keychain says — which is only the
    /// demo, whose store the Keychain has never heard of.
    private let storageLocations: [StorageKind: URL]?

    /// What the connection is doing right now: direct, or through the local listener.
    ///
    /// Forwarded rather than exposing the service itself — the settings screen needs this one
    /// answer, not the ability to sign anybody in.
    public func tunnelStatus() async -> TunnelStatus {
        await authentication.tunnelStatus()
    }

    /// This device's nostr key, as `npub1…`, for the settings screen to show and for somebody to
    /// paste into a closed bridge's `ALLOWED_PUBKEYS`.
    public func tunnelPublicKey() async -> String? {
        await authentication.tunnelPublicKey()
    }

    /// The homeserver, as the homeserver — never this app's own listener.
    ///
    /// With the bridge on, the SDK believes it is talking to `http://127.0.0.1:<port>`, because it
    /// is. Anything that wants the *real* address, like the bridge check, has to be given the
    /// server the listener stands in for instead.
    public var homeserverURL: URL {
        let known = TunnelSettings.persistableHomeserver(client.homeserver())
        return URL(string: known) ?? URL(string: "https://matrix.org")!
    }

    /// Which of the accounts on this device this is — the random ID that names its record in the
    /// Keychain and its three directories on disk. See `SessionStore`.
    public let sessionID: String

    public init(client: Client, authentication: AuthenticationService, sessionID: String,
                isDemo: Bool = false, storageLocations: [StorageKind: URL]? = nil) {
        self.client = client
        self.authentication = authentication
        self.sessionID = sessionID
        self.isDemo = isDemo
        self.storageLocations = storageLocations
        let userID = (try? client.userId()) ?? ""
        self.userID = userID
        self.deviceID = try? client.deviceId()
        self.displayName = Self.localPart(of: userID)
        // This account's nicknames from now on, not whoever was open before it.
        LocalNames.use(account: sessionID)
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
    /// closes, the box empties on its own and the next visit builds a new one — except for the
    /// handful in `recentTimelines`, which are deliberately kept.
    ///
    /// **`@ObservationIgnored`, and it has to be.** This is read from inside a view's `body` —
    /// that is the whole point of it — and it is written on the way past. On an `@Observable`
    /// class, a write is an invalidation of every view observing the session, so a write during
    /// a body is a body that asks to be run again, which writes again. It is not a slow loop: it
    /// spins the main thread at 100%, the app shows a white screen, and the footprint was past a
    /// gigabyte by the time it was sampled. A cache is not state anybody is watching, and saying
    /// so here is what keeps it out of the view graph.
    @ObservationIgnored private var openTimelines: [String: WeakBox<TimelineStore>] = [:]

    /// The identity watch of every room on screen, for the same two reasons as `openTimelines`:
    /// one per room, and every one of them stopped on the way out of the account.
    @ObservationIgnored private var openIdentityChanges: [String: WeakBox<IdentityChangesStore>] = [:]

    private struct WeakBox<T: AnyObject> {
        weak var value: T?
    }

    /// The last few conversations, kept alive after their screen has gone.
    ///
    /// Leaving a room used to throw its store away, so coming back a moment later rebuilt it from
    /// nothing: a new timeline, a listener that opens with an empty reset, and the whole first
    /// screenful fetched again before there was a word to show. Going back and forth between two
    /// chats — which is most of how a messenger is used — paid that price every single time, and
    /// it is the price the reader reads as "the app is slow to open a chat".
    ///
    /// A kept store comes back already holding its rows. `stop()` is a pause and leaves them
    /// alone, and `start()` finds them there and takes the reopening path, which holds the
    /// conversation on screen while it catches up. So the second visit has nothing to wait for.
    ///
    /// Three, and no cleverness beyond that. It is the depth of the "ask a question in one chat,
    /// answer it in another, go back" that this exists for; a longer list would hold SDK timeline
    /// items for rooms nobody is going to open again. Most recent first.
    ///
    /// Ordered by when a store was *built*, and not touched again when one is handed out a second
    /// time. A room being read is held by its own screen and needs nothing from this list, so
    /// re-ordering on read would buy nothing — and it is a write on the one path that is walked
    /// from inside a view's body. See the note on `openTimelines`.
    /// `@ObservationIgnored` for the same reason as `openTimelines`, and this is the one that
    /// proved it: bumping a conversation to the front on every read put a write in the middle of
    /// a body that had just read it.
    @ObservationIgnored private var recentTimelines: [TimelineStore] = []

    /// How many conversations are kept. See `recentTimelines`.
    private static let timelinesKept = 3

    /// Starts the sync loop. Everything else follows from this.
    public func start() async throws {
        // Said first, so that "Add account" signed in to this same person is refused while this
        // session is holding the store it would otherwise replace. See `AuthenticationService.persist`.
        if !isDemo { await authentication.sessionOpened(sessionID) }
        // Closed while that was being said: say the other thing, so the two arrive in order.
        guard !closed else {
            if !isDemo { await authentication.sessionClosed(sessionID) }
            return
        }

        // Before the sync loop, not after: the token can be refused by the very first request the
        // loop makes, and a delegate registered afterwards would miss it.
        authErrorHandle = try? client.setDelegate(delegate: AuthErrors { [weak self] in
            Task { @MainActor [weak self] in
                await self?.endedElsewhere()
            }
        })

        await loadProfile()
        // Every `await` in here is a moment `close()` or `signOut()` can run in — an account
        // switch on a cold launch from a push, the bridge changed while the first profile fetch
        // hung. Carrying on regardless registered listeners and started a sync loop for a session
        // that had already been closed, on a client nothing would ever stop.
        guard !closed else { return }

        // Before the room list, because it is the only listener in the app that has to be in place
        // for something *other people's devices* do. Everything else here is started so that this
        // device can ask a question; this is started so that it can be asked one.
        await verification.listen()
        guard !closed else {
            verification.stop()
            return
        }

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

        // Not awaited: whether the server hears "online" or "offline" first is not worth the chat
        // list waiting for. See `applyPresence`.
        Task { [weak self] in await self?.applyPresence() }

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
        //
        // Never for the demo. The session in the Keychain is somebody's real one.
        guard !isDemo else { return }
        await authentication.forgetSession(sessionID)
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

        keep(store)

        // The empty boxes go on the way past. There is no timer and no bookkeeping: a box is added
        // only when a room is opened, and nobody opens enough rooms in one sitting for the sweep to
        // be worth thinking about.
        openTimelines = openTimelines.filter { $0.value.value != nil }
        openTimelines[roomID] = WeakBox(value: store)

        return store
    }

    /// Who in this room has keys this device does not recognise — see `IdentityChangesStore`.
    ///
    /// The one already open, if the room is on screen twice (an iPad's list and detail): two
    /// subscriptions would each take the warning down on their own, and one of them late.
    public func identityChanges(forRoomID roomID: String) -> IdentityChangesStore? {
        if let open = openIdentityChanges[roomID]?.value { return open }
        guard let room = roomList.room(withID: roomID) ?? (try? client.getRoom(roomId: roomID)) else {
            return nil
        }
        let store = IdentityChangesStore(room: room, encryption: client.encryption(), ownUserID: userID)
        openIdentityChanges = openIdentityChanges.filter { $0.value.value != nil }
        openIdentityChanges[roomID] = WeakBox(value: store)
        return store
    }

    /// A timeline for *looking* at a room without going into it — the chat list's peek.
    ///
    /// Always a fresh store, and never the one `timeline(forRoomID:)` hands out, for two reasons.
    /// The peek stops its store when it closes, and on an iPad the same room may be open in the
    /// column beside the list: stopping a shared store would freeze the conversation somebody is
    /// reading. And it is not kept among the recent few, because a glance is not a visit.
    ///
    /// Nothing here marks anything read. A `TimelineStore` never sends a receipt on its own —
    /// `markAsRead()` is only ever called by the room screen — and that is the whole promise the
    /// peek makes. `DemoBackendTests` holds it to it.
    public func peekTimeline(forRoomID roomID: String) -> TimelineStore? {
        guard let room = roomList.room(withID: roomID) ?? (try? client.getRoom(roomId: roomID)) else {
            return nil
        }
        return TimelineStore(room: room, ownUserID: userID)
    }

    /// Moves a conversation to the front of the kept few, and lets the oldest go. See
    /// `recentTimelines`.
    ///
    /// The one being dropped is *not* stopped on the way out. It was stopped when its screen went
    /// away, and if it was not — a room still open in the detail column beside the list — then it
    /// is still somebody's, and this is only letting go of a second reference to it.
    private func keep(_ store: TimelineStore) {
        recentTimelines.removeAll { $0 === store }
        recentTimelines.insert(store, at: 0)
        if recentTimelines.count > Self.timelinesKept {
            recentTimelines.removeLast(recentTimelines.count - Self.timelinesKept)
        }
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

    /// What became of one thing from the outbox.
    public enum OutboxSend: Sendable, Equatable {
        /// In the room's send queue — encrypted, persistent, and the queue's to deliver from here.
        case sent
        /// Not now — the room would not open (offline, and never opened on this device; a store
        /// that stalled). It goes back in the outbox and is tried the next time the app comes up.
        case later
        /// Never: the file is gone, or the room is not one this account knows. Nothing to keep.
        case impossible
    }

    /// Sends one item the Share extension or Shortcuts left in the outbox, and hands back what
    /// could not go yet — to be put back, not thrown away.
    ///
    /// The outbox used to be emptied *before* anything was sent, and a send that could not open
    /// its room — offline, into a chat never opened on this device — simply returned false to a
    /// caller that did not look. The photo, the text, the file were gone without a word, when the
    /// room's own send queue would have held them until the network came back.
    ///
    /// The words wait for the pictures, as they always have: the photo first and "look at this"
    /// after it, so a text is never sent ahead of an attachment that is still waiting.
    public func sendQueued(_ item: ChatDirectory.OutboxItem) async -> ChatDirectory.OutboxItem? {
        // A room this account does not know — left, or never joined — is not a room to wait for.
        // Its copies go, and nothing comes back: an item queued for it would otherwise be retried
        // on every launch for ever.
        guard timeline(forRoomID: item.roomID) != nil else {
            // `send` finds no room either, and throws each copy away on its way to saying so.
            for attachment in item.attachments {
                _ = await send(attachment, toRoomID: item.roomID)
            }
            return nil
        }

        var waiting: [ChatDirectory.OutboxAttachment] = []
        for attachment in item.attachments where await send(attachment, toRoomID: item.roomID) == .later {
            waiting.append(attachment)
        }

        var text = item.text
        let hasWords = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if hasWords, waiting.isEmpty, await sendText(text, toRoomID: item.roomID) {
            text = ""
        } else if !hasWords {
            text = ""
        }

        guard !waiting.isEmpty || !text.isEmpty else { return nil }
        return ChatDirectory.OutboxItem(roomID: item.roomID, text: text, attachments: waiting,
                                        accountID: item.accountID)
    }

    /// Sends something the Share extension left in the outbox — a picture, a video or a file.
    ///
    /// The copy is deleted once the send queue has it, and when it can never be sent — it is the
    /// user's picture in the clear in a shared container. But *only* then: a send that merely has
    /// to wait keeps its file, or waiting would be losing it.
    public func send(_ attachment: ChatDirectory.OutboxAttachment, toRoomID roomID: String) async -> OutboxSend {
        // The name carries a folder of its own — see `OutboxAttachment.filename` — and the whole
        // folder goes with the file. It is resolved by `location(in:)` and nothing else: it came
        // from another process and, before that, from another app, and it used to be resolved
        // with `appending(path:)`, which follows `..` — up to the App Group's root.
        guard let folder = try? ChatDirectory.outboxFolder(environment: authentication.environment),
              let (url, slot) = attachment.location(in: folder) else { return .impossible }
        let discard = { try? FileManager.default.removeItem(at: slot) }

        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)),
              let target = timeline(forRoomID: roomID) else {
            discard()
            return .impossible
        }
        do {
            try await target.start()
        } catch {
            return .later
        }

        switch attachment.kind {
        case .image:
            guard let data = try? Data(contentsOf: url) else {
                discard()
                return .impossible
            }
            await target.send(photo: data, filename: attachment.displayName)
        case .video:
            await target.send(video: url)
        case .file:
            await target.send(file: url)
        }
        // Safe the moment the send returns: the SDK was handed the bytes — see `TimelineStore.owned`.
        discard()
        return .sent
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
    /// The account's sessions, for the Devices screen — see `AccountDevices`, which explains why
    /// this is a request of the app's own and the two rules that make it safe.
    public func accountDevices() -> AccountDevices? {
        guard let deviceID else { return nil }

        let client = client
        // Signed in through OAuth: the sessions are the server's to end, on its page.
        let isManagedByServer = ((try? client.session())?.oauthData) != nil

        return AccountDevices(
            userID: userID,
            currentDeviceID: deviceID,
            isManagedByServer: isManagedByServer,
            send: authorisedSender(),
            serverPage: { deviceID in
                let action: AccountManagementAction = deviceID.map { .deviceDelete(deviceId: $0) } ?? .devicesList
                return (try? await client.accountUrl(action: action)).flatMap { $0 }.flatMap(URL.init(string:))
            })
    }

    /// One request of the app's own with the account's token on it, sent the way the SDK's are —
    /// see `AccountDevices`, which explains why, and the two rules that make it safe.
    private func authorisedSender() -> @Sendable (ProxiedRequest) async throws -> ProxiedResponse {
        let client = client
        let authentication = authentication

        @Sendable func authorised(_ request: ProxiedRequest) throws -> ProxiedRequest {
            var request = request
            // Read at the moment of sending, never kept: a token the SDK has since refreshed must
            // not be replaced by the one it had when the screen opened.
            request.headers["Authorization"] = "Bearer \(try client.session().accessToken)"
            return request
        }

        return { request in
            let response = try await authentication.send(try authorised(request),
                                                         toHomeserver: client.homeserver())
            guard response.status == 401, Self.isExpiredToken(response.body) else { return response }

            // The token ran out, and only the SDK can refresh it — which it does when one of
            // *its* requests is refused. So one cheap request of its own, and then once more.
            _ = try? await client.displayName()
            return try await authentication.send(try authorised(request),
                                                 toHomeserver: client.homeserver())
        }
    }

    /// Tells the homeserver whether this account is online — or, with last seen hidden in
    /// Settings → Privacy, that it is not, whatever it is doing.
    ///
    /// The FFI has no presence call, so this is `PUT /presence/{userId}/status` of the app's own,
    /// through the same listener as everything else. Said on start and on every return to the
    /// foreground, because a server that counts a sync as "online" will have moved it back, and
    /// once more whenever the switch moves. A server with presence turned off answers 403 or 404
    /// and there is nothing to hide there anyway, so the answer is not looked at.
    public func applyPresence() async {
        guard !isDemo, !closed else { return }
        let hidden = PrivacySettings.hidesPresence()
        let body = (try? JSONSerialization.data(withJSONObject: ["presence": hidden ? "offline" : "online"])) ?? Data()
        let user = userID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(["/", ":"])) ?? userID
        let request = ProxiedRequest(method: "PUT",
                                     target: "/_matrix/client/v3/presence/\(user)/status",
                                     headers: ["Content-Type": "application/json"],
                                     body: body)
        _ = try? await authorisedSender()(request)
    }

    /// A 401 that means "your token has expired" and not "say your password" — the second is a
    /// question from User-Interactive Auth and carries flows, not this errcode.
    nonisolated private static func isExpiredToken(_ body: Data) -> Bool {
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        return json?["errcode"] as? String == "M_UNKNOWN_TOKEN"
    }

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

    /// Telling the homeserver where to send a push. See `PushRegistration`.
    public func pushes() -> PushRegistration {
        PushRegistration(client: client, accountID: sessionID)
    }

    /// What the account notifies about by default, for the screen that lets it be changed.
    ///
    /// Built on demand, like `storage()`: it holds an SDK `NotificationSettings` with a listener
    /// registration behind it, and a session that minted one at sign-in would carry it for the
    /// lifetime of the app on behalf of a screen almost nobody opens. See `NotificationRulesStore`.
    public func notificationRules() -> NotificationRulesStore {
        NotificationRulesStore(client: client)
    }

    /// Asking the homeserver to send a push when somebody reacts — which by default it will not.
    /// See `ReactionPushRule`, which explains why the rule has to be this broad and where the
    /// noise it invites is taken back out.
    public func enableReactionPushes() async {
        await ReactionPushRule(settings: client.getNotificationSettings()).register()
    }

    /// What this account is keeping on the device, built when the screen that shows it is opened.
    ///
    /// It takes the room list with it, and not for the rooms: clearing the cache means taking the
    /// sync service down and bringing it back up, and the room list is the only thing that holds
    /// one.
    public func storage() -> StorageStore {
        StorageStore(client: client, roomList: roomList, locations: storageLocations ?? authentication.storageURLs(sessionID: sessionID))
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

        // The demo's store is thrown away when the next demo starts, and the Keychain it would
        // otherwise empty belongs to the real account. See `DemoBackend`.
        guard !isDemo else { return }
        await authentication.signOut(client: client, sessionID: sessionID)
    }

    /// Stops the session without signing out of anything — for switching between the demo and the
    /// real account, where both are still there afterwards.
    public func close() async {
        authErrorHandle?.cancel()
        authErrorHandle = nil
        await stopEverything()
    }

    /// The app has gone into the user's pocket, or come back out of it.
    ///
    /// Only the sync loop is affected, and only on iOS — see `RoomListStore.pause()`, which explains
    /// why the reason is the notification extension rather than the battery.
    public func enteredBackground() async {
        await roomList.pause()
    }

    public func enteredForeground() async {
        // The transport first, then sync. In the other order the first sync after a wake is the
        // request that discovers the listener was reclaimed or the relays hung up, and the SDK
        // reports "no network" for as long as its own retry takes to come round.
        if !isDemo { await authentication.wakeTunnels() }
        await roomList.resume()
        await applyPresence()
    }

    /// Everything this session handed out that is still listening to the SDK.
    ///
    /// Called from both ways out — the user signing out, and the server having already signed them
    /// out — because the store on the disk goes away in both, and a room left open in the detail
    /// column does not know that.
    /// Set on the way out and never cleared: a session that has been closed is not opened again —
    /// the root builds a new one. What `start()` checks after every `await`.
    @ObservationIgnored private var closed = false

    private func stopEverything() async {
        closed = true
        if !isDemo { await authentication.sessionClosed(sessionID) }
        verification.stop()
        recovery.stop()

        for box in openTimelines.values {
            box.value?.stop()
        }
        openTimelines = [:]
        for box in openIdentityChanges.values {
            box.value?.stop()
        }
        openIdentityChanges = [:]
        // The kept conversations go too. They are rooms in a store that is about to be deleted.
        recentTimelines = []

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
