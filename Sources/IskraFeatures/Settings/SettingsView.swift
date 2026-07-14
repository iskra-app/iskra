import SwiftUI
import PhotosUI
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
    var onSignOut: () -> Void

    /// Emptying the cache leaves the SDK's client unusable, so the app has to build a new one —
    /// see `StorageStore.clearCache`. Only the root of the app can, which is where this goes.
    var onClearedCache: () -> Void

    /// What is in the name field, which is not the same thing as what the user is called.
    /// The name is sent when the field is *left*, not on every keystroke — the same
    /// arrangement as the room's name in `RoomInfoView`, and there is no Save button here
    /// either.
    @State private var draftName = ""
    @FocusState private var isNamingSelf: Bool

    @State private var isChoosingPicture = false
    @State private var pickedPicture: PhotosPickerItem?

    /// A change to the account the server would not make — including a picture the photo
    /// library would not hand over, which never reached the server at all. It lives here,
    /// with the alert that shows it, rather than on `UserSession`: the session outlives
    /// every screen, and the dismiss state of one screen's alert has no business in it.
    @State private var failure: AccountActionFailure?

    /// The one place this screen can go that is worth building lazily — see the
    /// `navigationDestination` below.
    private enum Destination: Hashable {
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

    var body: some View {
        Form {
            Section {
                profile
            }

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

                unbuilt(Strings.Settings.notifications, systemImage: "bell")
            } footer: {
                Text(Strings.Settings.moreSoon)
            }

            Section {
                Button(role: .destructive) {
                    onSignOut()
                } label: {
                    Text(Strings.Account.signOut)
                }
            } footer: {
                about
            }
        }
        .formStyle(.grouped)
        .tint(accent.color)
        .navigationTitle(Text(Strings.Settings.title))
        .toolbarTitleDisplayMode(.inline)
        // Value-based, because a `NavigationLink` with a destination *closure* builds that
        // destination eagerly, on every pass of this `body` — and this body re-runs on every
        // keystroke in the name field. `session.recovery()` allocates an SDK `Encryption`
        // object and a store, so the link-with-a-closure version minted and threw away one
        // of each per character typed. This closure runs when the row is actually pushed.
        .navigationDestination(for: Destination.self) { destination in
            switch destination {
            case .encryption:
                EncryptionView(recovery: session.recovery(),
                               verification: session.verification(),
                               deviceID: session.deviceID)
            case .storage:
                // Built here, on the push, for the same reason as the encryption screen above:
                // a `NavigationLink` with a destination closure builds it on every pass of this
                // body, and this body re-runs on every keystroke in the name field.
                StorageView(storage: session.storage(), onCleared: onClearedCache)
            }
        }
        // The field follows the session while it is not being typed in — the name can
        // change under us, from another device — and stops following it the moment it has
        // focus, or a sync landing mid-word would rewrite what is being typed.
        .onChange(of: session.displayName, initial: true) { _, name in
            guard !isNamingSelf else { return }
            draftName = name
        }
        .onChange(of: isNamingSelf) { wasNaming, _ in
            guard wasNaming else { return }
            Task { await rename() }
        }
        // And leaving the screen is leaving the field — the same reason as `RoomInfoView`. Focus
        // loss is what commits the name, and SwiftUI does not guarantee focus resigns before the
        // view is torn down, so closing settings with the keyboard still up lost the new name.
        // `UserSession.rename` returns early when nothing changed, so this cannot double-send.
        .onDisappear {
            guard isNamingSelf else { return }
            Task { await rename() }
        }
        // At the root of the screen, never inside the menu that asks for it: a
        // `PhotosPicker` declared inside a `Menu` simply never appears.
        .photosPicker(isPresented: $isChoosingPicture, selection: $pickedPicture, matching: .images)
        .onChange(of: pickedPicture) { _, item in
            guard let item else { return }
            Task { await setPicture(item) }
        }
        .failureAlert($failure)
        .toolbar {
            if showsBackButton {
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

    /// Who you are — and, since both halves of it are yours to change, where you change
    /// them. There is no Edit button and no pencil in the corner: the picture is the thing
    /// you press to change the picture, and the name is a field.
    ///
    /// The Matrix ID underneath is the one part that is not editable, ever, and it is shown
    /// in full and selectable because it is the thing people ask each other for.
    private var profile: some View {
        HStack(spacing: Theme.Spacing.roomy) {
            picture

            VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                TextField(String(app: Strings.Account.namePlaceholder), text: $draftName)
                    .font(.title3.weight(.semibold))
                    .textFieldStyle(.plain)
                    .lineLimit(1)
                    .focused($isNamingSelf)
                    .onSubmit { isNamingSelf = false }

                Text(session.userID)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, Theme.Spacing.close)
    }

    /// The face, and a menu on the face itself.
    private var picture: some View {
        Menu {
            Button {
                isChoosingPicture = true
            } label: {
                Label(String(app: Strings.Account.changePicture), systemImage: "photo")
            }

            if session.avatarURL != nil {
                Button(role: .destructive) {
                    Task { await removePicture() }
                } label: {
                    Label(String(app: Strings.Account.removePicture), systemImage: "trash")
                }
            }
        } label: {
            Avatar(name: session.displayName,
                   url: session.avatarURL,
                   size: Theme.Size.avatarLarge)
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .accessibilityLabel(Text(Strings.Account.changePicture))
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

    /// The three changes this screen can make, each turning the session's typed refusal
    /// into the alert. They are methods rather than `do/catch` written inline in a `Task`,
    /// because inside a `Task` closure Swift loses the thrown type and hands back a bare
    /// `any Error` — which will not fit the failure the alert is driven by.
    private func rename() async {
        do {
            try await session.rename(to: draftName)
        } catch {
            failure = error
        }
    }

    private func removePicture() async {
        do {
            try await session.removePicture()
        } catch {
            failure = error
        }
    }

    private func setPicture(_ item: PhotosPickerItem) async {
        pickedPicture = nil

        guard let data = await imageData(from: item) else {
            failure = .picture
            return
        }

        do {
            try await session.setPicture(data, filename: "avatar.jpg")
        } catch {
            failure = error
        }
    }
}
