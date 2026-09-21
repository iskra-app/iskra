import SwiftUI
import IskraCore
import IskraDesign

/// The whole app, from launch to conversation.
///
/// One `NavigationSplitView` serves all three platforms: it collapses to a stack on
/// iPhone, shows a sidebar on iPad and Mac, and handles the size-class transitions
/// on its own. That is the entire reason to use the system's navigation container
/// rather than building one — it already knows things we would spend months learning.
public struct IskraRootView: View {
    @State private var phase: Phase = .starting

    /// The lock over the whole app. Made once, here, from the App-Group settings so the choice is
    /// one the notification extension could also read. Off by default, so it changes nothing until
    /// the user turns it on in settings.
    @State private var appLock = AppLock(defaults: UserDefaults(suiteName: AppEnvironment.appGroupIdentifier))

    @State private var selectedRoomID: String?

    /// The *message* the room is being opened on, when it is being opened on one — searching finds
    /// a message, not a room, and landing at the bottom of the conversation it happens to be in is
    /// not an answer to what was asked.
    ///
    /// Cleared by `RoomView` once it has gone there, so that coming back to the same room later by
    /// ordinary means does not jump anywhere.
    @State private var selectedEventID: String?

    /// The colour the app is painted in, chosen on the appearance screen and read back
    /// here — the one place high enough that everything below it is tinted at once.
    @AppStorage(AccentTheme.storageKey) private var accent: AccentTheme = .default

    /// Light or dark, when the user has asked for one of them — and nothing at all when they have
    /// not, which is why this is applied as an *optional* scheme and not as a flag.
    @AppStorage(AppearanceMode.storageKey) private var appearance: AppearanceMode = .default

    /// Whether the accent is washed across the whole interface — every screen's background, the
    /// words on it, the message bubbles — and not only spent on the content that is already the
    /// user's. See the wash below, and `AccentTheme.tintsInterfaceKey` for why it is off by default.
    @AppStorage(AccentTheme.tintsInterfaceKey) private var tintsInterface = false

    /// Whether this device has already been shown what the app is — see `Onboarding` and
    /// `WelcomeView`. False on a fresh install, and the slides are what stands where the sign-in
    /// screen otherwise would.
    @AppStorage(Onboarding.welcomeSeenKey) private var hasSeenWelcome = false

    /// Read here, *outside* the `NavigationSplitView`, because this is the only place it
    /// means what it appears to mean: the size class of the window. Inside the split view
    /// each column gets the size class its own width earns, so the sidebar reports
    /// `.compact` on a full-screen iPad. See `RoomListView.isSidebar`.
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// Whether the app is in front. Read here rather than in a screen, because the sync loop belongs
    /// to the session and not to any one of them — see the `.onChange` below.
    @Environment(\.scenePhase) private var scenePhase

    private enum Phase {
        case starting
        case signedOut
        /// Signed in, and the session could not be brought up because the network is not there.
        ///
        /// A state of its own, because the two ways a launch can fail to produce a session are not
        /// the same thing and must not look the same. See `restore()`.
        case offline
        /// Signed in, and not yet let into the conversations: this account's encryption is being
        /// settled first. See `RecoverySetupView`.
        ///
        /// Reached from a *sign-in*, and deliberately never from a restore. Somebody signing in on a
        /// new phone has a question waiting for them — can this device read your history, and if not,
        /// how — and it has to be answered before they are handed a list of conversations that will
        /// not open. Somebody who merely reopened the app answered it long ago, and asking again
        /// every morning would be the app forgetting rather than remembering.
        case settingUp(UserSession)
        /// Signed in, encryption settled, and being shown the first run: a hello by name, the
        /// colour, and the faces. See `FirstRunView`.
        ///
        /// After the encryption question and not before it, although the two colour screens come
        /// last in the order somebody describes this flow. The reason is that one of these is a
        /// question about the account and the other two are questions about taste: an app that
        /// asks what colour it should be and *then* asks whether this device can read your history
        /// has put the trivial question in front of the one that decides what the app can do.
        case decorating(UserSession)
        case signedIn(UserSession)
    }

    /// Set when the session was ended somewhere else and the app took itself back to sign-in on
    /// its own. It has to be *said*: a person who left the app on a chat and comes back to a
    /// sign-in screen will assume the app lost their account, and go looking for the bug in the
    /// wrong place — which is exactly where the developer would go looking too.
    @State private var wasSignedOutRemotely = false

    /// The server's own sessions page, resolved once the session is up.
    ///
    /// It is read here, at the root, for the sake of one moment on the verification sheet: a device
    /// signs in, the user says it is not theirs, and the app has to be able to *do* something about
    /// that rather than merely say so. Ending a session is not something the FFI exports — this URL
    /// is the only door there is, and the root is where the incoming request lands, so this is where
    /// the door has to be held. `nil` on a server that hands over no such page, and the sheet then
    /// simply has one button instead of two.
    @State private var devicesURL: URL?

    private let authentication = AuthenticationService()

    public init() {
        // Every scroll view in the app hands touches on immediately, so the press that lifts a
        // message is the length it says it is — see `ScrollTouches`.
        ScrollTouches.stopDelaying()

        // The generated-faces switch moved into the App Group's defaults so that the notification
        // extension can read it too — and somebody who turned it on before it moved would
        // otherwise find it back off, and their lock screen disagreeing with their chat list.
        // See `BetaFeatures.faceStore`.
        BetaFeatures.adoptFaceFlags()
    }

    public var body: some View {
        Group {
            switch phase {
            case .starting:
                ProgressView()
                    .task { await restore() }

            case .signedOut:
                // The slides first, once per device. They are what this app is, said before
                // anybody is asked to type an address into it — and `hasSeenWelcome` is not
                // forgotten on sign-out, deliberately: somebody signing out to change accounts,
                // or signed out by a server that ended their session, has not forgotten what
                // Iskra is. See `Onboarding`.
                if hasSeenWelcome {
                    SignInView { session in
                        phase = .settingUp(session)
                    }
                } else {
                    WelcomeView { hasSeenWelcome = true }
                }

            case .offline:
                offlineStart

            case let .settingUp(session):
                // The session is started *here*, before the screen, and not after it. The whole
                // screen is a question about what this device can decrypt, and there is nothing to
                // ask until the sync loop is up and the SDK has talked to the server — so the
                // sign-in seam handing over a session it had not started would have made the first
                // thing the user sees a spinner over an account nobody was syncing.
                RecoverySetupView(session: session) {
                    phase = .decorating(session)
                }
                .task { try? await session.start() }

            case let .decorating(session):
                FirstRunView(session: session) {
                    phase = .signedIn(session)
                }

            case let .signedIn(session):
                conversations(session)
                    // The message menu, above every screen the signed-in app has — see
                    // `MessageMenu`. It lifts a message out of the conversation and darkens
                    // everything else, and "everything else" is the toolbar above the timeline
                    // and the composer below it as much as the messages between them. Inside the
                    // navigation stack it would stop at both, leaving a dimmed conversation
                    // between a bright title bar and a bright text field.
                    //
                    // *Before* the environment below it and not after, which is the one thing
                    // about this line that is easy to get wrong and impossible to see. The menu
                    // draws a second copy of the message over the darkened room, and an overlay
                    // inherits the environment of the view it is attached to — not of that view's
                    // contents. Put on last, the lifted copy would be the only bubble in the app
                    // with no media loader: a photograph would lift off the page as an empty
                    // rectangle, and only ever in the menu.
                    .messageMenuLayer()
                    .environment(\.mediaLoader, session.media())
                    // Handed down so a bubble can tell a mention of *you* from a mention of anyone
                    // else, without being given the session to do it.
                    .environment(\.currentUserID, session.userID)
                    .environment(\.currentUserName, session.displayName)
                    .environment(\.blockStore, session.blocked)
                    .environment(\.forwarding, Forwarding(session: session))
                    // Writing to somebody whose name was pressed in a room's member list, and the
                    // one wire that lets a screen several pushes deep in the conversation column
                    // change which conversation that column is showing. See `PersonalChats`.
                    .environment(\.personalChats, PersonalChats(session: session))
                    .environment(\.openRoom, { roomID in
                        selectedRoomID = roomID
                        selectedEventID = nil
                    })
                    // Notifications are asked for *here*, and the timing is the whole of the
                    // decision. On the sign-in screen the question is about nothing — no account,
                    // no chats, nothing that could notify anybody — and it gets the answer a
                    // question about nothing deserves, once, permanently. Here there are
                    // conversations on the screen behind the prompt, and the question means what
                    // it says.
                    .task {
                        PushPermission.shared.signedIn(session)
                        await PushPermission.shared.request()
                        // And ask the server to tell us about reactions, which by default it will
                        // not — see `ReactionPushRule`. Written on the account rather than the
                        // device, so this is idempotent and costs one request.
                        await session.enableReactionPushes()
                    }
                    // The server stopped accepting this session while the app was open — somebody
                    // ended it from another device, or the account was deactivated. `UserSession`
                    // has already torn down the local half; what is left is to take the screens
                    // down with it and say what happened, because the alternative is what this
                    // used to do: nothing at all, on an app that goes on looking connected while
                    // every message it sends waits in a queue for a server that will not have it.
                    .onChange(of: session.wasEndedElsewhere) { _, wasEnded in
                        guard wasEnded else { return }
                        AppSettings.forget()
                        // Somebody else's unread count has no business staying on the icon of an
                        // app nobody is signed into.
                        AppBadge.clear()
                        selectedRoomID = nil
                        selectedEventID = nil
                        phase = .signedOut
                        wasSignedOutRemotely = true
                    }
                    // A device of this user's is signing in and asking to be trusted. It is put up
                    // here, at the root, rather than on the encryption screen where the *outgoing*
                    // verification lives — and that is the whole difference between the two
                    // directions. Asking to be verified is something the user goes somewhere to do.
                    // Being asked is something that happens to them, while they are reading a chat,
                    // and the question has to reach them there or it does not reach them at all.
                    //
                    // The sheet answers for itself: it cannot be swiped away while the question is
                    // on it, and it takes itself down when the store has nothing left to say. See
                    // `VerificationSheet`.
                    .sheet(isPresented: Binding(get: { session.verification.incoming != nil },
                                                set: { if !$0 { session.verification.reset() } })) {
                        VerificationSheet(verification: session.verification,
                                          onDone: { session.verification.reset() },
                                          devicesURL: devicesURL)
                    }
                    // Asked for once, and long before it is needed. The moment it *is* needed — the
                    // user has just told the app a device is not theirs — is the worst possible moment
                    // to start a network round-trip and leave them looking at a sheet that has not
                    // decided yet whether it can help them.
                    .task { devicesURL = await session.deviceManagementURL() }
                    // The sync loop goes down with the app, on the phone. Not to save battery — iOS
                    // suspends the process anyway — but because the moment the app is in a pocket is
                    // the moment a push arrives, and a push wakes the notification extension, which
                    // is a *second process* opening the same SQLite store. An app suspended
                    // mid-write holds that store for as long as the system feels like.
                    //
                    // Not on the Mac: an app that is merely not in front is still one the user
                    // expects to be receiving messages, and no extension is racing it for the file.
                    #if os(iOS)
                    .onChange(of: scenePhase) { _, phase in
                        Task {
                            switch phase {
                            case .background: await session.enteredBackground()
                            case .active: await session.enteredForeground()
                            default: break
                            }
                        }
                    }
                    #endif
                    // Keep the App-Intents chat directory in step, so Siri and Shortcuts can list the
                    // conversations without waking a client — see `ChatDirectory`.
                    .onChange(of: session.roomList.rooms, initial: true) { _, rooms in
                        writeChatDirectory(rooms)
                        // And the number on the icon, from the same list and at the same moment,
                        // so that reading a chat takes the count down without anybody asking it to.
                        AppBadge.update(for: rooms)
                    }
                    // Act on what an intent asked for: open the chat it launched us for, and send any
                    // messages it left in the outbox. Once on appear (a cold launch by an intent), and
                    // again whenever we come back to the front.
                    .task { await handleIntents(session) }
                    .onChange(of: scenePhase) { _, phase in
                        if phase == .active { Task { await handleIntents(session) } }
                    }
                    // A tapped notification asked for a conversation. It does not go through the
                    // intents slot above: that one lives in the shared defaults because Shortcuts
                    // runs in another process, and a tap does not — it arrives here, on this actor,
                    // at a moment that races the very foreground it causes. See `PushRouter`.
                    //
                    // Read on appear as well as on change, because a tap on a cold launch is
                    // delivered long before this tree exists.
                    .task { openRoomAskedForByANotification() }
                    .onChange(of: PushRouter.shared.roomToOpen) { _, roomID in
                        guard roomID != nil else { return }
                        openRoomAskedForByANotification()
                    }
                    // And the other direction: the router is what decides whether a push is worth a
                    // banner, and the one case where it is not is a message in the conversation
                    // already on screen.
                    .onChange(of: selectedRoomID, initial: true) { _, roomID in
                        PushRouter.shared.visibleRoomID = roomID
                    }
                    .onChange(of: scenePhase) { _, phase in
                        // Nothing is "on screen" when the app is not. Without this, going straight
                        // from a conversation into a pocket silences every push from it.
                        PushRouter.shared.visibleRoomID = phase == .active ? selectedRoomID : nil
                    }
            }
        }
        .animation(.smooth, value: isSignedIn)
        .alert(Text(Strings.Session.endedTitle), isPresented: $wasSignedOutRemotely) {
            Button(String(app: Strings.Problem.ok), role: .cancel) {}
        } message: {
            Text(Strings.Session.endedMessage)
        }
        // "Тонировать интерфейс": a single translucent sheet of the accent, laid over the whole
        // app so that every screen's background, the words on it and the bubbles all take a breath
        // of the colour at once — not the accent spent only on the content that is already yours,
        // but the whole surface bathed in it.
        //
        // It is an *overlay* and not a background, and that is not a stylistic choice. The screens
        // in this app sit on the system's own grouped-list and page backgrounds, which are drawn
        // opaque and answer to no colour we hand down — a tint laid *under* them would never be
        // seen. Laid *over* everything, ignoring the safe area and deaf to touches, the wash reaches
        // the system's backgrounds, the content, and the text with the one lever that reaches them
        // all. Faint enough (`Theme.Tint.interface`) that it colours rather than dims. The chrome is
        // handed the accent in the same breath, so the tinted app is tinted through and through
        // rather than washed content under monochrome controls.
        //
        // Off, the app is exactly what it was: `.primary` chrome and no wash — the accent spent only
        // where it means something, the messages you sent, the reactions that are yours, the send
        // button about to make one.
        //
        // `.mono` is allowed here, and used not to be: the switch was disabled on the colourless
        // theme because its colour *is* `.primary`, so the wash dims the app rather than colouring
        // it. True, and not a reason to refuse — that dimming is what a black-and-white theme
        // spreading over the interface looks like, and somebody who picks the colourless theme and
        // then asks for it everywhere has asked for something that makes sense. It is washed with a
        // lighter hand instead, because darkness has no hue to spend and starts eating the words at
        // the opacity a colour is fine at. See `AccentTheme.washOpacity`.
        .tint(tintsInterface ? accent.color : .primary)
        .overlay {
            if tintsInterface {
                accent.color
                    .opacity(accent.washOpacity)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
        }
        .animation(.smooth(duration: Theme.Timing.reaction), value: tintsInterface)
        .environment(\.appLock, appLock)
        // The cover the app wears on its way out, so that the picture iOS keeps for the app switcher
        // is a padlock and not somebody's conversation — see `PrivacyCover`.
        //
        // Deliberately unanimated, and that is the whole trick. The system photographs the app as it
        // leaves; a cover that fades in over a quarter of a second is photographed half-transparent,
        // with the conversation legible straight through it. `nil` against the scene phase says "no
        // animation for this one change" — scoped to the phase rather than a blanket `.transaction`,
        // which would strip the animation from every child in the app.
        .overlay {
            if PrivacyCover.isNeeded(lockEnabled: appLock.isEnabled, phase: scenePhase) {
                PrivacyCover()
            }
        }
        .animation(nil, value: scenePhase)
        // The shield, above everything — the tint, a sheet, a media viewer — because a lock that any
        // screen could sit on top of is not a lock. It is here, at the very root, for the same reason
        // the colour scheme is.
        .overlay {
            if appLock.isLocked {
                LockScreen(appLock: appLock)
                    .transition(.opacity)
            }
        }
        .animation(.smooth(duration: Theme.Timing.chrome), value: appLock.isLocked)
        // Driving the lock is separate from the sync teardown below: the lock cares about every trip
        // away, signed in or not, and on the Mac as well as the phone.
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            // Only a true trip to the background records a leaving-time — `.inactive` is the app
            // switcher and the notification pull-down, and locking on those would close the shield
            // every time the user glanced at a banner.
            case .background: appLock.enteredBackground()
            case .active: appLock.enteredForeground()
            default: break
            }
        }
        .environment(\.accent, accent)
        // And light or dark, if the user asked for either. Applied at the root, above everything,
        // because a colour scheme is not a property of a screen — a sheet or a media viewer left
        // out of it would be the one place the app changed its mind about what time of day it is.
        .preferredColorScheme(appearance.colorScheme)
    }

    private var isSignedIn: Bool {
        if case .signedIn = phase { return true }
        return false
    }

    /// Writes the joined conversations (not spaces, not invitations) into the shared directory the
    /// App Intents read. Names only — nothing an intent needs to fetch.
    private func writeChatDirectory(_ rooms: [RoomSummary]) {
        let entries = rooms
            .filter { !$0.isInvitation && !$0.isSpace }
            .map { ChatDirectoryEntry(id: $0.id, name: $0.name) }
        ChatDirectory.writeDirectory(entries)
    }

    /// Acts on what a Shortcuts intent left behind: opens the chat it asked for, and sends the
    /// messages it queued. Draining is one-shot — the reads clear the shared slots — so this is safe
    /// to call on every foreground.
    private func handleIntents(_ session: UserSession) async {
        if let roomID = ChatDirectory.takePendingOpen() {
            selectedRoomID = roomID
        }
        for item in ChatDirectory.drainOutbox() {
            await session.sendText(item.text, toRoomID: item.roomID)
        }
    }

    /// Opens whatever conversation a tapped banner asked for, if one did.
    ///
    /// Takes the room rather than reading it, so that a later foreground — the app comes back after
    /// the reader has gone somewhere else themselves — does not drag them back to a chat they have
    /// already left.
    private func openRoomAskedForByANotification() {
        guard let roomID = PushRouter.shared.takeRoomToOpen() else { return }
        selectedRoomID = roomID
        selectedEventID = nil
    }

    /// Signing out unwinds everything: the session, the selected room, and — because the
    /// whole signed-in tree goes away with it — the settings screen it was asked for on.
    ///
    /// `async`, and awaited by the button that calls it, rather than firing a detached `Task` and
    /// returning at once. It is not instant — it tells the server to stop pushing, ends the session,
    /// and deletes the encrypted store — and while it ran, the screen it was pressed on sat there
    /// looking untouched. So it got pressed again. Now the caller can await it and say so.
    private func signOut(_ session: UserSession) async {
        // Before the session goes, because telling the server to stop pushing here is a request
        // that needs the session to make it. Without it the homeserver goes on pushing this
        // account's messages to a phone that has been signed out of: the extension wakes, finds
        // nobody signed in, and shows the server's own "New message" — notifications, forever,
        // about conversations the user can no longer open.
        await PushPermission.shared.signingOut(session)

        await session.signOut()

        // And any document handed to another application on the way. `SessionStore.clear` knows
        // about the encrypted store and nothing about a PDF copied out of it in the clear so
        // that Preview could open it — see `FileOpener.handOff`. A decrypted file must not
        // outlive the account it came from.
        #if os(macOS)
        FileOpener.sweep()
        #endif

        AppSettings.forget()
        AppBadge.clear()
        selectedRoomID = nil
        selectedEventID = nil
        phase = .signedOut
    }

    /// The launch that could not reach the server.
    ///
    /// Deliberately not a sign-in screen and deliberately not an error: nothing has gone wrong with
    /// the account, and saying so is the entire job of this view. "Try again" goes back to
    /// `.starting`, which runs `restore()` again — the same road `restart()` takes, and for the same
    /// reason: the session is still in the Keychain, waiting.
    private var offlineStart: some View {
        ContentUnavailableView {
            Label(Strings.Session.offlineTitle, systemImage: "wifi.slash")
        } description: {
            Text(Strings.Session.offlineMessage)
        } actions: {
            Button(String(app: Strings.Session.tryAgain)) {
                phase = .starting
            }
            .buttonStyle(.primaryAction)
        }
    }

    /// Builds the app a new client, without signing anybody out.
    ///
    /// This is what emptying the cache costs. `Client.clearCaches` says so itself — "the Client
    /// will be in an unstable state, and it is required that the caller reinstantiates a new
    /// Client instance" — and it is not a formality: the store the client was reading has been
    /// pulled out from under it. Going on with the old one is why the button appeared to do
    /// nothing at all.
    ///
    /// Going back to `.starting` is the whole of it: the signed-in tree comes down, taking the
    /// settings screen and the old session with it, and the progress view's `.task` runs
    /// `restore()` again — which builds a fresh client from the session that is still, untouched,
    /// in the Keychain. Nobody is signed out; the account, the keys and the messages on the server
    /// are exactly where they were, and what was thrown away downloads again.
    private func restart() {
        selectedRoomID = nil
        selectedEventID = nil
        phase = .starting
    }

    /// True where the sidebar stays on screen — Mac, and iPad wide enough to keep the split
    /// view expanded. False on iPhone, and on an iPad squeezed narrow enough that the split
    /// view collapses to a stack, which is right: there the list *is* the screen, and it
    /// should look like it does on a phone.
    private var isSidebar: Bool {
        #if os(macOS)
        true
        #else
        horizontalSizeClass == .regular
        #endif
    }

    private func conversations(_ session: UserSession) -> some View {
        NavigationSplitView {
            // Settings is pushed onto this column's own navigation stack, so the push,
            // the back button and the swipe-back gesture all come from the system.
            // Sign-out, though, unwinds the whole app, so only this view can do it.
            RoomListView(session: session,
                         selectedRoomID: $selectedRoomID,
                         selectedEventID: $selectedEventID,
                         isSidebar: isSidebar,
                         onSignOut: { await signOut(session) },
                         onClearedCache: { restart() })
                // Fixed rather than content-derived, so that opening settings — a `Form`
                // pushed onto a column holding a `Form` — cannot move the column under the
                // room list. This was once believed to be the cure for the macOS settings
                // hang as well, and measurement says it is not: the hang survives both an
                // absolute width and no width at all. Its real cause was one property in
                // `SettingsView` — see `SettingsView.onClose`. The width stays because a
                // column that resizes itself when you open settings is its own small bug.
                // See `Theme.Size.sidebar*`.
                .navigationSplitViewColumnWidth(min: Theme.Size.sidebarMinimum,
                                                ideal: Theme.Size.sidebarIdeal,
                                                max: Theme.Size.sidebarMaximum)
        } detail: {
            // The stack is load-bearing, and its absence fails in a way that looks like
            // nothing at all: a `navigationDestination` declared inside a split view's
            // detail column has no stack to push onto, so it silently does nothing. The
            // room-info screen behind the chat header was simply never appearing, and no
            // warning was logged. The sidebar column gets a stack of its own from the
            // split view — which is why settings pushed and this did not.
            NavigationStack {
                if let roomID = selectedRoomID, let timeline = session.timeline(forRoomID: roomID) {
                    // Leaving the room empties this column: the room list drops the room on
                    // its own, but the *selection* still points at it, and on iPhone that
                    // would leave the reader pushed onto a conversation that no longer
                    // exists.
                    RoomView(timeline: timeline,
                             makeDetails: { session.details(forRoomID: roomID) },
                             openAt: $selectedEventID,
                             onLeave: { selectedRoomID = nil },
                             makeCall: { session.call(forRoomID: roomID) },
                             mayCall: { await session.canStartCall(inRoomID: roomID) })
                        // Rebuilds the view when the user picks a different room, rather
                        // than reusing one room's state for another's messages.
                        .id(roomID)
                } else {
                    ContentUnavailableView(String(app: Strings.Room.noRoomSelectedTitle),
                                           systemImage: "bubble.left.and.bubble.right",
                                           description: Text(Strings.Room.noRoomSelectedMessage))
                }
            }
        }
        // Said once, here, and read by both columns. The room list and the room are in different
        // branches of the tree and both have to know, and the session is the only thing that is
        // above both of them. See `OfflineBanner`.
        .environment(\.isOffline, session.roomList.isOffline)
    }

    /// Brings back the signed-in user, if there is one, before showing anything.
    private func restore() async {
        // Whatever the last run left lying about. A file opened on the Mac is copied out of the
        // encrypted store in the clear so another application can read it, and the app is never
        // told when that application is finished — so the sweeping is done at the two moments we
        // *are* here: launch, and sign-out.
        #if os(macOS)
        FileOpener.sweep()
        #endif

        // And whatever the last run left in the *container*: encrypted stores belonging to sign-ins
        // that never finished and sessions that have been replaced. They are readable — the
        // passphrase is stable — so they are not litter, they are a copy of the conversations with
        // nothing pointing at it. This is the one moment it is safe to say so; see
        // `sweepOrphanedStores`.
        await authentication.sweepOrphanedStores()

        do {
            if let session = try await authentication.restorePreviousSession() {
                phase = .signedIn(session)
                try? await session.start()
                return
            }
        } catch AuthenticationError.networkUnavailable {
            // Never the sign-in screen for this. The account is fine — the tokens are in the
            // Keychain, the conversations are in the store, and the only thing missing is the
            // network. Sending somebody to "Sign in" here tells them their account is gone, which
            // is untrue and frightening, and it is what the app used to do to anybody who opened it
            // in a tunnel: an empty `catch` treated a lost network and a dead session as one fact.
            phase = .offline
            return
        } catch {
            // A session we cannot restore is a session the user must create again.
            // Falling through to sign-in is the honest outcome.
        }
        phase = .signedOut
    }
}
