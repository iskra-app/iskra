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
            }
        }
        .animation(.smooth, value: isSignedIn)
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
            selectedRoomID = nil
            phase = .signedOut
        }
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
                         onSignOut: { signOut(session) })
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
