import SwiftUI
import IskraCore
import IskraDesign

/// Settings, reached by tapping your own face in the top-right corner.
///
/// A destination pushed onto the room list's navigation stack — deliberately *not* a
/// sheet, and deliberately not a view swapped in behind a transition of our own. Being
/// a real destination is what makes the push, the back button and the swipe-back
/// gesture the system's rather than ours, and the difference is visible at a glance.
/// So there is no `NavigationStack` here: it is already inside one.
///
/// The back button is the one thing the system does not always supply. On iPhone it does,
/// and this screen must not draw a second one. Inside a sidebar it does not, and this
/// screen must — see `showsBackButton`.
///
/// Notifications is the one row here that is still structure without a feature behind it.
/// It is shown, and shown disabled, rather than hidden: the shape of the screen is a
/// promise about where things will go, and a row that is greyed out with a sentence
/// explaining why is honest in a way that an empty screen is not.
///
/// Signing out is the one thing on this screen that cannot be undone, so it is last and it
/// is red.
struct SettingsView: View {
    /// Held, not owned — the session outlives this screen, and `@Observable` tracks it
    /// through a plain `let` just as well.
    let session: UserSession

    /// The app lock, put up by the root. Nil only where the root has not — never in the real app.
    @Environment(\.appLock) private var appLock

    /// `async`, because signing out is not instant and this screen has to be able to say so — it
    /// ends the session on the server and deletes the encrypted store. As a plain closure it
    /// returned immediately, the screen sat there looking untouched, and the button got pressed
    /// again by somebody who had every reason to think the first press had missed.
    var onSignOut: () async -> Void

    /// Emptying the cache leaves the SDK's client unusable, so the app has to build a new one —
    /// see `StorageStore.clearCache`. Only the root of the app can, which is where this goes.
    var onClearedCache: () -> Void

    /// Set when the sign-out starts, and never cleared — see the button.
    @State private var isSigningOut = false

    /// Where this account's devices are managed — on the server's own page, because there is nowhere
    /// in this app they could be. Resolved once, on appearance; `nil` means the session did not come
    /// through OAuth and there is no such page, and then the row is not drawn at all.
    @State private var devicesURL: URL?

    /// The one place this screen can go that is worth building lazily — see the
    /// `navigationDestination` below.
    private enum Destination: Hashable {
        case profile
        case encryption
        case storage
    }

    /// Whether this screen has to draw its own way out.
    ///
    /// On iPhone it does not: settings is pushed onto the whole screen, and the system
    /// puts a back chevron in the corner and wires the swipe-back gesture to it. In a
    /// *sidebar* — Mac, and iPad wide enough to keep the split view open — it does: the
    /// column is only a few hundred points wide, the push happens inside it, and no back
    /// button appears, so without this the screen is a room with no door and sign-out is
    /// the only way out of it.
    let showsBackButton: Bool

    @Environment(\.dismiss) private var dismiss

    /// The one screen whose chrome is allowed the colour. A `Label` in a `Form` draws its
    /// icon in the tint, and the app's tint is monochrome everywhere else (see
    /// `IskraRootView`) — so the accent is put back here, on this screen only, where a row
    /// of coloured symbols is the point rather than noise.
    @Environment(\.accent) private var accent

    // TEMP DIAGNOSTIC — locating the macOS settings layout hang. Remove once found.
    // Launch with e.g. `ISKRA_NOSELECT=1 .../Iskra.app/Contents/MacOS/Iskra` to disable one suspect.
    private static func dbgOff(_ key: String) -> Bool {
        ProcessInfo.processInfo.environment["ISKRA_" + key] == "1"
    }

    var body: some View {
        Form {
            Section {
                if Self.dbgOff("NOPROFILE") { Text(verbatim: "profile") } else { profile }
            }
            .profileHeaderRow()

            Section {
                NavigationLink {
                    AppearanceView()
                } label: {
                    Label(Strings.Settings.appearance, systemImage: "paintbrush")
                }

                NavigationLink {
                    QuickReactionView()
                } label: {
                    Label(Strings.Settings.reactions, systemImage: "heart")
                }

                NavigationLink(value: Destination.encryption) {
                    Label(Strings.Settings.encryption, systemImage: "lock")
                }

                NavigationLink(value: Destination.storage) {
                    Label(Strings.Settings.storage, systemImage: "internaldrive")
                }

                NavigationLink {
                    ConnectionView(session: session)
                } label: {
                    Label(
                        Strings.Settings.connection,
                        systemImage: "point.3.filled.connected.trianglepath.dotted"
                    )
                }

                NavigationLink {
                    BlockedUsersView(store: session.blocked)
                } label: {
                    Label(Strings.Settings.blocked, systemImage: "hand.raised")
                }

                unbuilt(Strings.Settings.notifications, systemImage: "bell")
            } footer: {
                Text(Strings.Settings.moreSoon)
            }

            if let appLock {
                lockSection(appLock)
            }

            // The devices, which live somewhere else — and the row is only here when there is
            // somewhere else for it to lead to.
            //
            // There is no native list and there is not going to be one. The Rust SDK has `devices()`
            // and `delete_devices()`; the FFI deliberately exports neither, and on a homeserver
            // running the authentication service the endpoint that deletes a device answers 404 —
            // it is gone, not guarded. What the SDK *does* hand over is the address of the page that
            // can do it, opened with the session the user already has, which is Element X's answer
            // to the same wall.
            //
            // `deviceManagementURL()` is nil when the session was not obtained through OAuth, and
            // then this section simply is not drawn. A row that led nowhere would be worse than no
            // row: it would be the app claiming it could do something it cannot.
            if let devicesURL {
                Section {
                    // Opened in the app's own browser rather than thrown to Safari, and that is what
                    // carries the sign-in across: the same `ASWebAuthenticationSession` that signed
                    // the user in shares its cookies, so the server's page recognises them and does
                    // not ask them to sign in again to see their own devices.
                    Button {
                        Task { await WebAuthentication.approve(url: devicesURL) }
                    } label: {
                        LabeledContent {
                            Image(systemName: "arrow.up.forward.app")
                                .foregroundStyle(.secondary)
                        } label: {
                            Label(Strings.Settings.devices, systemImage: "laptopcomputer.and.iphone")
                        }
                    }
                } footer: {
                    Text(Strings.Settings.devicesHelp)
                }
            }

            Section {
                Button(role: .destructive) {
                    isSigningOut = true
                    Task { await onSignOut() }
                } label: {
                    // The spinner sits beside the words rather than replacing them, so the row does
                    // not change height or lose its label at the moment it becomes unpressable —
                    // the button still says what it is doing while it does it.
                    //
                    // `isSigningOut` is never set back to false, and does not need to be: signing
                    // out ends by taking the whole signed-in tree down, this screen with it. If it
                    // fails, the session is already half torn down and there is nothing here to go
                    // back to — the app goes to the sign-in screen either way.
                    HStack(spacing: Theme.Spacing.close) {
                        Text(Strings.Account.signOut)
                        if isSigningOut {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(isSigningOut)
            } footer: {
                about
            }
        }
        .formStyle(.grouped)
        .tint(Self.dbgOff("NOTINT") ? Color.primary : accent.color)
        .profileScreen()
        // Value-based, because a `NavigationLink` with a destination *closure* builds that
        // destination eagerly, on every pass of this `body`. `session.storage()` allocates a store
        // and takes the room list with it, so the link-with-a-closure version minted and threw one
        // away every time anything on this screen changed — and when the name was still a field up
        // here, that was once per character typed. This closure runs when the row is pushed.
        .navigationDestination(for: Destination.self) { destination in
            switch destination {
            case .profile:
                ProfileEditView(session: session)
            case .encryption:
                EncryptionView(recovery: session.recovery,
                               verification: session.verification,
                               deviceID: session.deviceID,
                               hasDeviceManagement: devicesURL != nil)
            case .storage:
                // Built here, on the push, for the same reason as the encryption screen above:
                // a `NavigationLink` with a destination closure builds it on every pass of this
                // body, and this body re-runs whenever anything on the screen moves.
                StorageView(storage: session.storage(), onCleared: onClearedCache)
            }
        }
        // Cheap: the SDK builds this out of OAuth metadata it has already cached, without going to
        // the network. It is still async, so it cannot be read straight out of `body`.
        .task { devicesURL = await session.deviceManagementURL() }
        .toolbar {
            // The one thing on this screen that is *yours* rather than the app's, so it gets the
            // corner. It is a pencil and not the word "Edit" because the corner opposite already
            // holds a back chevron on Mac, and two words facing each other across a title bar read
            // as a dialog rather than as a screen.
            ToolbarItem(placement: .primaryAction) {
                NavigationLink(value: Destination.profile) {
                    Image(systemName: "pencil")
                        .font(.body.weight(.medium))
                }
                .accessibilityLabel(Text(Strings.Account.edit))
            }

            if showsBackButton && !Self.dbgOff("NOBACK") {
                ToolbarItem(placement: .navigation) {
                    Button {
                        dismiss()
                    } label: {
                        // A chevron, and the word — this is the system's own back button
                        // spelled out by hand, so it should look like one.
                        Label(Strings.Settings.back, systemImage: "chevron.backward")
                    }
                    .accessibilityLabel(Text(Strings.Settings.back))
                }
            }
        }
    }

    /// Who you are: your picture, large and centred, your name under it, and the Matrix ID
    /// under that.
    ///
    /// Nothing here can be typed into, and the pencil in the corner is where both halves are
    /// changed — see `ProfileEditView`. It used to be a row with a text field in it, which meant
    /// settings opened with the cursor one tap away from your own name; the screen you read and
    /// the screen you edit are now two screens, and only one of them can lose anything.
    ///
    /// The Matrix ID is the one part that is not editable, ever, and it is shown in full and
    /// selectable because it is the thing people ask each other for.
    private var profile: some View {
        ProfileHeader(name: session.displayName,
                      avatarURL: session.avatarURL,
                      subtitle: session.userID,
                      isSubtitleSelectable: !Self.dbgOff("NOSELECT"))
    }

    /// The app saying what it is and which build of it this is.
    ///
    /// A footer rather than a row, and centred, because it is not a setting: there is nothing
    /// here to press. It sits below sign-out — the last thing on the screen, where every other
    /// app puts it, and where somebody who has come looking for a version number to quote in a
    /// bug report will look for it. The numbers come from the bundle; see `AppVersion`.
    private var about: some View {
        VStack(spacing: Theme.Spacing.tight) {
            Text(Strings.Settings.appName)
            Text(Strings.Settings.version(AppVersion.marketing, build: AppVersion.build))
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.top, Theme.Spacing.roomy)
        .textSelection(.enabled)
    }

    /// A setting that exists as a place on the screen and nothing more.
    private func unbuilt(_ title: LocalizedStringResource, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .foregroundStyle(.secondary)
    }

    /// The app-lock controls: a switch, and — once it is on — how long a trip away is forgiven. The
    /// switch is `@Bindable` on the lock itself, so flipping it writes straight through to the store
    /// that persists it. When the device has no passcode of its own there is nothing to lean on, so
    /// the switch is disabled and says why.
    @ViewBuilder
    private func lockSection(_ appLock: AppLock) -> some View {
        @Bindable var appLock = appLock
        Section {
            Toggle(isOn: $appLock.isEnabled) {
                Label(Strings.Settings.lockEnable, systemImage: "faceid")
            }
            .accentControl()
            .disabled(!appLock.canAuthenticate)

            if appLock.isEnabled {
                Picker(selection: $appLock.timeout) {
                    ForEach(AppLockTimeout.allCases) { option in
                        Text(Strings.Settings.lockTimeoutLabel(option)).tag(option)
                    }
                } label: {
                    Label(Strings.Settings.lockTimeout, systemImage: "clock")
                }
            }
        } header: {
            Text(Strings.Settings.lock)
        } footer: {
            Text(appLock.canAuthenticate ? Strings.Settings.lockExplanation : Strings.Settings.lockUnavailable)
        }
    }

}
