import SwiftUI
import IskraCore

/// The whole app, from launch to conversation.
///
/// One `NavigationSplitView` serves all three platforms: it collapses to a stack on
/// iPhone, shows a sidebar on iPad and Mac, and handles the size-class transitions
/// on its own. That is the entire reason to use the system's navigation container
/// rather than building one — it already knows things we would spend months learning.
public struct IskraRootView: View {
    @State private var phase: Phase = .starting
    @State private var selectedRoomID: String?

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
            }
        }
        .animation(.smooth, value: isSignedIn)
    }

    private var isSignedIn: Bool {
        if case .signedIn = phase { return true }
        return false
    }

    private func conversations(_ session: UserSession) -> some View {
        NavigationSplitView {
            RoomListView(session: session, selectedRoomID: $selectedRoomID)
                .toolbar {
                    ToolbarItem {
                        Menu {
                            Button("Sign out", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                                Task {
                                    await session.signOut()
                                    selectedRoomID = nil
                                    phase = .signedOut
                                }
                            }
                        } label: {
                            Label("Account", systemImage: "person.crop.circle")
                        }
                    }
                }
        } detail: {
            if let selectedRoomID, let timeline = session.timeline(forRoomID: selectedRoomID) {
                RoomView(timeline: timeline)
                    // Rebuilds the view when the user picks a different room, rather
                    // than reusing one room's state for another's messages.
                    .id(selectedRoomID)
            } else {
                ContentUnavailableView("Pick a chat",
                                       systemImage: "bubble.left.and.bubble.right",
                                       description: Text("Choose a conversation to start reading."))
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
