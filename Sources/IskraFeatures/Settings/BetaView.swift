import IskraCore
import IskraDesign
import SwiftUI

/// The unfinished things, and the switches that turn them on.
///
/// One screen rather than a switch tucked into whichever settings page a feature happens to touch,
/// because what these switches have in common is not their subject — it is their *status*. A
/// person who finds "Native sidebar" under Appearance has no way of knowing it is an experiment;
/// a person who finds it here cannot miss it, and the sentence at the top says the rest.
///
/// There is no row for it on the settings root. It is reached by tapping the spark on the About
/// screen three times — see `AboutView` — because the people these switches are for are the
/// people who will go looking, and everybody else is better off never seeing them. The sidebar
/// switch is the one thing here that is Mac-only; the rest of the screen is the same everywhere.
struct BetaView: View {
    /// The homeserver the session on screen really talks to — the client's own answer, after
    /// discovery, which is not always what was typed at sign-in. Nil where there is no session.
    var homeserver: String?

    @AppStorage(BetaFeatures.nativeSidebarKey) private var nativeSidebar = BetaFeatures.nativeSidebarByDefault
    @AppStorage(BetaFeatures.blobatarKey, store: BetaFeatures.faceStore) private var blobatar = BetaFeatures.blobatarByDefault
    @AppStorage(BetaFeatures.forceBlobatarKey, store: BetaFeatures.faceStore) private var forceBlobatar = BetaFeatures.forceBlobatarByDefault
    @AppStorage(BetaFeatures.mockBackendKey) private var mockBackend = false
    @AppStorage(BetaFeatures.showsEventSourceKey) private var showsEventSource = false
    @AppStorage(BetaFeatures.showsAllEventsKey) private var showsAllEvents = false

    /// The sign-in screen against the server inside the app — see `MockSignIn` — and its address
    /// once that server is up.
    @State private var demoServer: DemoServer?
    @State private var demoSignedIn: String?

    /// In the app's own defaults, not the App Group's: the notification extension has no use for
    /// it. Only the app places calls.
    @AppStorage(BetaFeatures.elementCallURLKey) private var elementCallURL = ""

    /// What the address was when this screen opened, so that leaving it without touching the field
    /// asks the server nothing.
    @State private var elementCallURLOnEntry = ""

    /// Told when the call address has actually been changed, so the session can look again.
    ///
    /// It exists because the availability of calls is worked out **once**, in `UserSession.start()`
    /// — two network questions whose only consequence is whether a button appears, and no reason
    /// to re-ask them while somebody reads a conversation. That is right for the server's answer
    /// and wrong for this field: without this, a person types an address here, goes back, finds no
    /// call button, and the only cure is restarting the app. The field would look broken, and the
    /// bug would be invisible — the address *was* saved.
    var onCallAddressChanged: (() -> Void)?

    var body: some View {
        Form {
            Section {
                Text(Strings.Beta.intro)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            // Who gets a drawn face — the slider the first run asks with. It lived under
            // Appearance; the faces are still an experiment, and the switches below it that
            // decide whether they are drawn at all were already here.
            Section {
                FaceModePicker()
                    .padding(.vertical, Theme.Spacing.close)
            } header: {
                Text(Strings.Appearance.avatars)
            }

            #if os(macOS)
            Section {
                Toggle(isOn: $nativeSidebar.animation(.smooth(duration: Theme.Timing.reaction))) {
                    Label(Strings.Beta.nativeSidebar, systemImage: "sidebar.left")
                }
                // The root tint is `.primary` unless the user has asked for the accent on the
                // chrome, and a switch drawn in `.primary` is white on white. Every switch in the
                // app goes through this — see `AccentControl`.
                .accentControl()
            } footer: {
                Text(Strings.Beta.nativeSidebarHelp)
            }
            #endif

            Section {
                Toggle(isOn: $blobatar.animation(.smooth(duration: Theme.Timing.reaction))) {
                    Label(Strings.Beta.blobatar, systemImage: "face.smiling")
                }
                .accentControl()
            } footer: {
                Text(Strings.Beta.blobatarHelp)
            }

            // Appears with the switch it depends on rather than sitting there greyed out: a
            // disabled row is the app showing somebody a thing they cannot have and not saying
            // why, and the answer — "turn the one above on" — is the row directly above it.
            if blobatar {
                Section {
                    Toggle(isOn: $forceBlobatar.animation(.smooth(duration: Theme.Timing.reaction))) {
                        Label(Strings.Beta.blobatarForce, systemImage: "person.crop.circle.badge.xmark")
                    }
                    .accentControl()
                } footer: {
                    Text(Strings.Beta.blobatarForceHelp)
                }
            }

            // A field rather than a switch, because the thing being chosen is not on-or-off: it
            // is an address, and there is no sensible one to offer. See `ElementCallDiscovery` on
            // why the app ships no default — and why the sentence under this field says what it
            // says instead of being a cheerful explanation of a feature.
            Section {
                TextField(text: $elementCallURL, prompt: Text(Strings.Beta.elementCallPrompt)) {
                    Label(Strings.Beta.elementCallTitle, systemImage: "phone.badge.waveform")
                }
                #if !os(macOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                #endif
                .autocorrectionDisabled()
            } footer: {
                Text(Strings.Beta.elementCallNote)
            }

            #if DEBUG
            // Flipping it takes the whole app with it — `IskraRootView` watches the same key and
            // swaps the session underneath this screen, so the switch is the last thing touched
            // in the account it was touched in. No confirmation: nothing is lost either way.
            Section {
                Toggle(isOn: $mockBackend) {
                    Label(Strings.Beta.mockBackend, systemImage: "theatermasks")
                }
                .accentControl()
            } footer: {
                Text(Strings.Beta.mockBackendHelp)
            }
            #endif

            if let homeserver {
                Section {
                    LabeledContent {
                        Text(verbatim: homeserver)
                    } label: {
                        Label(Strings.Beta.homeserver, systemImage: "server.rack")
                    }
                    .textSelection(.enabled)
                } header: {
                    Text(Strings.Beta.developers)
                } footer: {
                    Text(Strings.Beta.homeserverHelp)
                }
            }

            Section {
                #if DEBUG
                Button {
                    Task { demoServer = await MockSignIn.start().map(DemoServer.init) }
                } label: {
                    Label(Strings.Beta.demoSignIn, systemImage: "person.badge.key")
                }
                #endif
                Toggle(isOn: $showsEventSource) {
                    Label(Strings.Beta.showsSource, systemImage: "curlybraces")
                }
                .accentControl()
                Toggle(isOn: $showsAllEvents) {
                    Label(Strings.Beta.showsAllEvents, systemImage: "list.bullet.rectangle")
                }
                .accentControl()
            } header: {
                if homeserver == nil {
                    Text(Strings.Beta.developers)
                }
            } footer: {
                #if DEBUG
                Text(Strings.Beta.demoSignInHelp) + Text(verbatim: "\n\n") + Text(Strings.Beta.showsSourceHelp)
                    + Text(verbatim: "\n\n") + Text(Strings.Beta.showsAllEventsHelp)
                #else
                Text(Strings.Beta.showsSourceHelp) + Text(verbatim: "\n\n") + Text(Strings.Beta.showsAllEventsHelp)
                #endif
            }
        }
        .formStyle(.groupedRows)
        .navigationTitle(Text(Strings.Beta.title))
        .onAppear { elementCallURLOnEntry = elementCallURL }
        // On the way out rather than on every keystroke: half a typed address is a different
        // address, and asking the server about each one would be a network request per letter.
        // This screen pushes nothing, so `onDisappear` here means what it says — see the warning
        // about it in `RoomInfoView`, where it does not. The demo sign-in is a cover, and coming
        // back from it at worst asks the server once more.
        .onDisappear {
            guard elementCallURL != elementCallURLOnEntry else { return }
            onCallAddressChanged?()
        }
        #if os(iOS)
        .fullScreenCover(item: $demoServer) { server in demoSignIn(server.address) }
        #else
        .pageSheet(item: $demoServer) { server in
            demoSignIn(server.address)
                .frame(minWidth: Theme.Size.signInColumn, minHeight: Theme.Size.signInColumn * 4 / 3)
        }
        #endif
        .alert(Text(Strings.Beta.demoSignedIn(demoSignedIn ?? "")),
               isPresented: Binding(get: { demoSignedIn != nil }, set: { if !$0 { demoSignedIn = nil } })) {
            Button(String(app: Strings.Folders.done)) { demoSignedIn = nil }
        }
    }

    /// The real sign-in screen, the real SDK, a made-up server — and a session that is closed the
    /// moment it opens: the point is the way in, not what is behind it. Nothing touches the account
    /// on the device: `MockSignIn.authentication` keeps its store in scratch and its secrets in memory.
    private func demoSignIn(_ address: String) -> some View {
        NavigationStack {
            SignInView(authentication: MockSignIn.authentication, address: address) { session in
                let who = session.userID
                Task { await session.close() }
                demoServer = nil
                demoSignedIn = who
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(app: Strings.Beta.close)) { demoServer = nil }
                }
            }
        }
    }
}

/// The demo server's address, as something a cover can be presented for.
private struct DemoServer: Identifiable {
    let address: String
    var id: String { address }
}
