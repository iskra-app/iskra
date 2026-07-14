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

    /// Read here, *outside* the `NavigationSplitView`, because this is the only place it
    /// means what it appears to mean: the size class of the window. Inside the split view
    /// each column gets the size class its own width earns, so the sidebar reports
    /// `.compact` on a full-screen iPad. See `RoomListView.isSidebar`.
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private enum Phase {
        case starting
        case signedOut
        case signedIn(UserSession)
    }

    /// Set when the session was ended somewhere else and the app took itself back to sign-in on
    /// its own. It has to be *said*: a person who left the app on a chat and comes back to a
    /// sign-in screen will assume the app lost their account, and go looking for the bug in the
    /// wrong place — which is exactly where the developer would go looking too.
    @State private var wasSignedOutRemotely = false

    private let authentication = AuthenticationService()

    public init() {}

    public var body: some View {
        Group {
            switch phase {
            case .starting:
                ProgressView()
                    .task { await restore() }

            case .signedOut:
                SignInView { session in
                    phase = .signedIn(session)
                    Task { try? await session.start() }
                }

            case let .signedIn(session):
                conversations(session)
                    .environment(\.mediaLoader, session.media())
                    // The server stopped accepting this session while the app was open — somebody
                    // ended it from another device, or the account was deactivated. `UserSession`
                    // has already torn down the local half; what is left is to take the screens
                    // down with it and say what happened, because the alternative is what this
                    // used to do: nothing at all, on an app that goes on looking connected while
                    // every message it sends waits in a queue for a server that will not have it.
                    .onChange(of: session.wasEndedElsewhere) { _, wasEnded in
                        guard wasEnded else { return }
                        AppSettings.forget()
                        selectedRoomID = nil
                        selectedEventID = nil
                        phase = .signedOut
                        wasSignedOutRemotely = true
                    }
            }
        }
        .animation(.smooth, value: isSignedIn)
        .alert(Text(Strings.Session.endedTitle), isPresented: $wasSignedOutRemotely) {
            Button(String(app: Strings.Problem.ok), role: .cancel) {}
        } message: {
            Text(Strings.Session.endedMessage)
        }
        // The accent travels down the tree, but it is *not* handed to the system's controls
        // here. `.tint` is what buttons, links and the sidebar's selection read, and tinting
        // the whole app with it painted the chrome as loudly as the content: a green app had
        // green back chevrons, green rows and a green unread badge, and a colour that is
        // everywhere says nothing anywhere. The chrome is monochrome instead, and the accent
        // is spent only where it means something — the messages you sent, the reactions that
        // are yours, the send button that is about to make one, and the icons on the settings
        // screen, each of which asks for the colour where it stands.
        .tint(.primary)
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

    /// Signing out unwinds everything: the session, the selected room, and — because the
    /// whole signed-in tree goes away with it — the settings screen it was asked for on.
    private func signOut(_ session: UserSession) {
        Task {
            await session.signOut()
            AppSettings.forget()
            selectedRoomID = nil
            selectedEventID = nil
            phase = .signedOut
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
                         onSignOut: { signOut(session) },
                         onClearedCache: { restart() })
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
                             onLeave: { selectedRoomID = nil })
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
    }

    /// Brings back the signed-in user, if there is one, before showing anything.
    private func restore() async {
        do {
            if let client = try await authentication.restorePreviousSession() {
                let session = UserSession(client: client, authentication: authentication)
                phase = .signedIn(session)
                try? await session.start()
                return
            }
        } catch {
            // A session we cannot restore is a session the user must create again.
            // Falling through to sign-in is the honest outcome.
        }
        phase = .signedOut
    }
}
