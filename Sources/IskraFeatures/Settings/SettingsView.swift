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
/// Eight rows, and the shape of them is the point. This screen used to be a list of everything the
/// app could be told, in the order the features happened to be built: appearance, reactions,
/// encryption, storage, connection, blocked, a greyed-out notifications row, then a lock section,
/// then a devices section. Nine things, several of which were halves of each other — the devices
/// signed into this account sat one section away from a screen about this device; a switch marked
/// "Connection" that decides who can read your traffic sat two rows from the word "Encryption".
///
/// So they are gathered by the question they answer rather than by what they happen to be.
/// Appearance took the app icon and Security took the devices, the blocked list, the privacy
/// switches, the Face ID lock and the bridge. The beta features have no row at all — they are
/// three taps on the spark in About. Notifications stopped being a promise and became a screen —
/// see `NotificationsView`.
///
/// Signing out is the one thing on this screen that cannot be undone, so it is last and it
/// is red.
struct SettingsView: View {
    /// Held, not owned — the session outlives this screen, and `@Observable` tracks it
    /// through a plain `let` just as well.
    let session: UserSession

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
    /// Your own QR code — see `QRCodeSheet`.
    @State private var isShowingCode = false

    /// Another account, swiped to be signed out of and waiting for the answer to "are you sure".
    @State private var accountToSignOut: AccountRecord?

    /// Every page this screen pushes, built on the push — see the `navigationDestination` below.
    /// Held in a flag, `page`, rather than pushed by `NavigationLink`s, because this screen sits in
    /// the sidebar's stack, where the only safe way back is a flag its owner clears: that is what
    /// Escape does on a Mac (`escapeKey`). `dismiss` is not an option here — see `onClose`.
    private enum Page: Hashable {
        case profile
        case appearance
        case reactions
        case chats
        case folders
        case notifications
        case security
        case media
        case storage
        case about
        case language
    }

    /// The page pushed over this screen, if any.
    @State private var page: Page?

    /// Whether this screen has to draw its own way out.
    ///
    /// On iPhone it does not: settings is pushed onto the whole screen, and the system
    /// puts a back chevron in the corner and wires the swipe-back gesture to it. In a
    /// *sidebar* — Mac, and iPad wide enough to keep the split view open — it does: the
    /// column is only a few hundred points wide, the push happens inside it, and no back
    /// button appears, so without this the screen is a room with no door and sign-out is
    /// the only way out of it.
    let showsBackButton: Bool

    /// Closing the screen, handed down rather than taken from the environment.
    ///
    /// It would be `@Environment(\.dismiss)`, and it was, and that one property hung the app.
    /// `dismiss` is a dynamic property tied to the presentation this screen sits in, and this
    /// screen sits in the *sidebar column's* stack: on macOS 26, a view pushed there that both
    /// reads `dismiss` and pushes a screen of its own re-enters layout forever — the main thread
    /// spins at 100% inside `NSHostingView.layout()` and the window stops answering. It took
    /// every settings row down with it, because every settings row is a push from here.
    ///
    /// Nothing is lost by handing it down. The flag that opened this screen belongs to the room
    /// list (`isShowingSettings`), so the room list can perfectly well be the one to clear it,
    /// and a closure has no layout behaviour to go wrong. See `RoomListView`.
    var onClose: () -> Void

    /// The one screen whose chrome is allowed the colour. A `Label` in a `Form` draws its
    /// icon in the tint, and the app's tint is monochrome everywhere else (see
    /// `IskraRootView`) — so the accent is put back here, on this screen only, where a row
    /// of coloured symbols is the point rather than noise.
    @Environment(\.accent) private var accent

    /// The other accounts on the device, and the way to add one. See `AccountSwitcher`.
    @Environment(\.accountSwitcher) private var switcher

    /// Everybody but the account on screen, each a tap away, and "Add account" under them.
    ///
    /// Right under the profile, because it is the same question the profile answers — *who* the
    /// app is being — and the one somebody with two accounts comes here to change most often.
    private func accounts(_ switcher: AccountSwitcher) -> some View {
        Section {
            ForEach(switcher.others) { account in
                Button {
                    switcher.switchTo(account.sessionID)
                } label: {
                    AccountRow(account: account,
                               unread: switcher.unread[account.sessionID] ?? 0,
                               isSigningOut: switcher.signingOut.contains(account.sessionID))
                }
                .buttonStyle(.plain)
                .disabled(switcher.signingOut.contains(account.sessionID))
                // A swipe, as a chat is left from the chat list — and the same thing on a press,
                // because a Mac has no swipe to find it by.
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        accountToSignOut = account
                    } label: {
                        Label(String(app: Strings.Accounts.signOutShort),
                              systemImage: "rectangle.portrait.and.arrow.right")
                    }
                    // Red by hand. A swipe button takes the tint of the screen, and this screen is
                    // tinted with the accent — white on the mono one, so "Sign out" came up white.
                    .tint(.red)
                }
                .contextMenu {
                    Button(role: .destructive) {
                        accountToSignOut = account
                    } label: {
                        Label(String(app: Strings.Account.signOut),
                              systemImage: "rectangle.portrait.and.arrow.right")
                    }
                }
            }
            Button {
                switcher.addAccount()
            } label: {
                Label(Strings.Accounts.add, systemImage: "person.crop.circle.badge.plus")
            }
        } header: {
            if switcher.hasSeveral {
                Text(Strings.Accounts.section)
            }
        }
        .onAppear { switcher.refreshUnread() }
        // Asked, because it cannot be undone from here: the chats go off the device, and an
        // encrypted history comes back only with the recovery key.
        .confirmationDialog(Text(Strings.Accounts.signOutTitle(of: accountToSignOut.map(AccountSwitcher.name(of:)) ?? "")),
                            isPresented: Binding(get: { accountToSignOut != nil },
                                                 set: { if !$0 { accountToSignOut = nil } }),
                            titleVisibility: .visible,
                            presenting: accountToSignOut) { account in
            Button(role: .destructive) {
                switcher.signOut(account.sessionID)
            } label: {
                Text(Strings.Accounts.signOutShort)
            }
        } message: { _ in
            Text(Strings.Accounts.signOutMessage)
        }
    }

    /// "Sign out", or — when there is more than one account it could mean — whose.
    private var signOutTitle: LocalizedStringResource {
        guard switcher?.hasSeveral == true else { return Strings.Account.signOut }
        return Strings.Accounts.signOut(of: session.displayName)
    }

    var body: some View {
        Form {
            // The two ways of handing yourself to somebody, under your name — the same round tiles a
            // person's page has under theirs, so your own page and theirs are one design. In the
            // portrait's section, so the form's gap between sections does not open up under the name.
            Section {
                profile
                NavigationGlassGroup(spacing: Theme.Spacing.close) {
                    HStack(spacing: Theme.Spacing.close) {
                        ShareLink(item: MatrixLink.user(session.userID).url) {
                            ProfileActionTileLabel(title: Strings.Profile.share, systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.plain)

                        ProfileActionTile(title: Strings.QR.title, systemImage: "qrcode", isBusy: false) {
                            isShowingCode = true
                        }
                    }
                }
                .padding(.bottom, Theme.Spacing.close)
            }
            .profileHeaderRow()

            if let switcher, switcher.isAvailable {
                accounts(switcher)
            }

            Section {
                PushRow {
                    page = .appearance
                } label: {
                    Label(Strings.Settings.appearance, systemImage: "paintbrush")
                }

                // A list of its own on a Mac; on iPhone and iPad the app's page in the system
                // Settings, where iOS keeps the language of every app. See `LanguageView`.
                PushRow {
                    #if os(macOS)
                    page = .language
                    #else
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                    #endif
                } label: {
                    Label(Strings.Settings.language, systemImage: "globe")
                }

                // Next to appearance rather than inside it. What the double tap sends is not a
                // decision about how a conversation *looks* — it is what a gesture does — and it
                // is a word people arrive at settings already looking for. See `ReactionsView`.
                PushRow {
                    page = .reactions
                } label: {
                    Label(Strings.Settings.reactions, systemImage: "face.smiling")
                }

                // How conversations behave rather than how they look: the grey lines, the Return
                // key, the share sheet's account. See `ChatSettingsView`.
                PushRow {
                    page = .chats
                } label: {
                    Label(Strings.Settings.chats, systemImage: "bubble.left.and.bubble.right")
                }

                // Folders of chats, as tabs over the list — see `FoldersView`.
                PushRow {
                    page = .folders
                } label: {
                    Label(Strings.Folders.title, systemImage: "folder")
                }

                PushRow { page = .notifications } label: {
                    Label(Strings.Settings.notifications, systemImage: "bell")
                }

                // A shield rather than a padlock, and that is the rename saying itself in the
                // margin: a padlock is a picture of encryption, and this screen is no longer only
                // about encryption. It took the devices, the blocked list and the privacy
                // switches too — see `SecurityView`.
                PushRow { page = .security } label: {
                    Label(Strings.Settings.security, systemImage: "lock.shield")
                }

                // Before storage: both are about the bytes photos and videos cost, and this one is
                // the question people come to settings with — "why did it send so big".
                PushRow {
                    page = .media
                } label: {
                    Label(Strings.Settings.media, systemImage: "photo.on.rectangle")
                }

                PushRow { page = .storage } label: {
                    Label(Strings.Settings.storage, systemImage: "internaldrive")
                }

                // Last, because it is the one row that changes nothing. It is also the only place
                // the version is shown, and the only way to the beta features — three taps on the
                // spark there. See `AboutView`.
                PushRow {
                    page = .about
                } label: {
                    Label(Strings.Settings.about, systemImage: "info.circle")
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
                        Text(signOutTitle)
                        if isSigningOut {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(isSigningOut)
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $isShowingCode) {
            QRCodeSheet(name: session.displayName, subtitle: session.userID,
                        avatarURL: session.avatarURL, seed: session.userID,
                        link: .user(session.userID))
        }
        .tint(accent.color)
        .profileScreen()
        // Built on the push, never on a pass of this body — see `pageView`. A `NavigationLink`
        // with a destination closure built `session.storage()` every time anything here changed,
        // once per character typed when the name was still a field up here.
        .navigationDestination(item: $page) { page in
            pageView(page)
                .escapeKey { self.page = nil }
        }
        // Escape, on a Mac: back to the chat list, as the chevron in the corner does. Only in the
        // sidebar — on a phone this is a push the system already knows how to undo.
        .escapeKey { if showsBackButton { onClose() } }        .toolbar {
            // The one thing on this screen that is *yours* rather than the app's, so it gets the
            // corner. It is a pencil and not the word "Edit" because the corner opposite already
            // holds a back chevron on Mac, and two words facing each other across a title bar read
            // as a dialog rather than as a screen.
            ToolbarItem(placement: .primaryAction) {
                Button { page = .profile } label: {
                    Image(systemName: "pencil")
                        .font(.body.weight(.medium))
                }
                .accessibilityLabel(Text(Strings.Account.edit))
            }

            if showsBackButton {
                ToolbarItem(placement: .navigation) {
                    Button {
                        onClose()
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

    /// What each page is. Built here, on the push: `notificationRules()` builds a store with an
    /// SDK listener behind it and `session.storage()` takes the room list with it, and a
    /// `NavigationLink` with a destination closure built them on every pass of this body.
    @ViewBuilder
    private func pageView(_ page: Page) -> some View {
        switch page {
        case .profile:
            ProfileEditView(session: session)
        case .appearance:
            AppearanceView()
        case .reactions:
            ReactionsView()
        case .chats:
            ChatSettingsView()
        case .folders:
            FoldersView(folders: session.folders, roomList: session.roomList)
        case .media:
            MediaSettingsView()
        case .about:
            AboutView(homeserver: session.homeserverURL.absoluteString)
        case .language:
            LanguageView()
        case .notifications:
            NotificationsView(rules: session.notificationRules())
        case .security:
            SecurityView(session: session,
                         recovery: session.recovery,
                         verification: session.verification)
        case .storage:
            StorageView(storage: session.storage(), onCleared: onClearedCache)
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
                      seed: session.userID,
                      isSubtitleSelectable: true)
    }
}
