import SwiftUI
import IskraCore
import IskraDesign

/// Who can get at this account, and from where.
///
/// This was `EncryptionView`, and the rename is not cosmetic. The screen never did answer "is
/// end-to-end encryption enabled" — in this app it always is, in every private room, and there is
/// no switch for it. It answers the question people discover the hard way on the day they get a
/// new phone: *will I still be able to read any of this?* That is why the state is called
/// `HistoryProtection` and not `RecoveryState`, and why the word "key" only appears where the user
/// has to physically handle one.
///
/// More things were asking halves of the same question from separate rows on the settings root —
/// the other devices signed into this account, who is blocked, what others can see of you, the
/// Face ID lock on the app, and whether traffic goes through a bridge that can see it. Scattered,
/// each read as a small preference; gathered here, under a name that covers them, they read as one
/// subject.
///
/// The order goes from what most needs attention to what can least be undone: whether the history
/// is safe, and this device if it is not yet trusted; then who else is in the account and who is
/// kept out of it; what others see of you; the lock and the bridge; and last, in red, the button
/// that throws the old recovery code away.
///
/// The recovery key itself is shown exactly once, in a sheet with no way to dismiss it except the
/// button that says the user has saved it. That is not an interaction pattern anyone enjoys,
/// and it is the correct one: a recovery key the user swiped away is a recovery key they do
/// not have, and they find that out months later, from a screen that cannot help them.
struct SecurityView: View {
    /// The session, which this screen needs for what it has taken in: the bridge screen is built
    /// over it, the device list and the blocked list are asked of it, and the presence switch is
    /// told to it.
    let session: UserSession

    /// The app lock, put up by the root. Nil only where the root has not — never in the real app.
    /// It used to be read by `SettingsView`, which drew the switch itself.
    @Environment(\.appLock) private var appLock

    /// What others learn without your writing anything — moved here from a screen of their own.
    /// Typing is read on the next keystroke; presence is told to the server the moment the switch
    /// moves, because "hide when I was last here" that takes effect next time is a switch that did
    /// not work today.
    @AppStorage(PrivacySettings.hidesPresenceKey) private var hidesPresence = PrivacySettings.hidesPresenceByDefault
    @AppStorage(PrivacySettings.hidesTypingKey) private var hidesTyping = PrivacySettings.hidesTypingByDefault

    /// The page pushed over this screen — a flag rather than a `NavigationLink`, so Escape can take
    /// it back (`escapeKey`): this screen can sit in the sidebar's stack, where `dismiss` is out.
    private enum Page: Hashable {
        case devices
        case blocked
        case connection
    }

    @State private var page: Page?

    /// The session's, not this screen's — a plain `let`, exactly like `verification` below.
    ///
    /// It used to be built by this screen and torn down with it, which was fine while this screen was
    /// the only thing that asked. It is not: the room list carries a banner about a recovery code
    /// that was never saved, and a banner cannot ask a question that only settings knows the answer
    /// to. State that everything needs cannot belong to one screen.
    let recovery: RecoveryStore

    /// What is being typed into the field, when the key is being typed rather than made.
    @State private var typedKey = ""

    /// Proving this device is yours. Owned by the session, not by this screen — it has to keep
    /// listening for devices asking to be trusted long after this screen is closed, and it is
    /// perfectly ordinary to never open this screen at all. Held as a plain `let`: `@Observable`
    /// tracks it through one just as well, and `@State` here would mean this screen decided when
    /// it lived and died, which it does not.
    let verification: VerificationStore

    @State private var isVerifying = false

    /// The code just minted, for exactly as long as this sheet shows it — and nowhere else. See the
    /// sheet below for why it is not on the store any more.
    @State private var freshCode: RecoveryKey?

    /// Whether the "are you sure" for a new code is up. See the button.
    @State private var isMintingNewCode = false

    init(session: UserSession,
         recovery: RecoveryStore,
         verification: VerificationStore) {
        self.session = session
        self.recovery = recovery
        self.verification = verification
    }

    var body: some View {
        Form {
            state

            if !recovery.isDeviceVerified {
                thisDevice
            }

            people

            privacy

            if let appLock {
                lockSection(appLock)
            }

            if recovery.protection == .on {
                Section {
                    // Asks first. Minting a code destroys the one before it, permanently and with no
                    // undo, and this row used to do that on a single tap — as did the room-list
                    // banner, which is how a real recovery code was lost. The footer already said the
                    // old code would stop working; a footer is not a question, and people press
                    // buttons without reading footers. Settings is the only place a code is minted
                    // deliberately now, so this dialog is the only place the question is asked.
                    //
                    // Red, and last on the screen: it is the one thing here that cannot be undone.
                    Button(role: .destructive) {
                        isMintingNewCode = true
                    } label: {
                        working(Strings.Encryption.newKey)
                    }
                    .disabled(recovery.isWorking)
                } footer: {
                    Text(Strings.Encryption.newKeyHelp)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(Text(Strings.Settings.security))
        .toolbarTitleDisplayMode(.inline)
        .onChange(of: hidesPresence) {
            Task { await session.applyPresence() }
        }
        .navigationDestination(item: $page) { page in
            Group {
                switch page {
                case .devices:
                    if let devices = session.accountDevices() {
                        DevicesView(store: DevicesStore(source: devices))
                    }
                case .blocked:
                    BlockedUsersView(store: session.blocked)
                case .connection:
                    ConnectionView(session: session)
                }
            }
        }
        // Neither store is stopped here any more, and neither is started here. Both belong to the
        // session and outlive this screen — `load()` is called once, when the session starts. Tearing
        // either down on the way out would unhook a listener the rest of the app is reading: the
        // banner in the room list watches the same recovery state this screen does.
        .sheet(isPresented: $isVerifying) {
            VerificationSheet(verification: verification) {
                isVerifying = false
                verification.reset()
            }
        }
        // Presented from the root of the screen rather than from the row that produces the
        // code: the row is inside a `Section` that stops being drawn the moment `protection`
        // flips to `.on`, and a sheet attached to a view that has just been removed never
        // opens. The code would then be minted, held, and shown to nobody.
        //
        // The code is this screen's, in `@State`, and not the session store's. It used to be the
        // store's — and the store is the session's, so the code outlived the screen that made it and
        // was visible to every other screen that cared to look. Two views bound sheets to the same
        // optional and could clear it out from under each other. Held here, it exists while this
        // sheet is up and is gone when it is not, which is what "shown once" has to mean.
        .confirmationDialog(Text(Strings.Recovery.newTitle),
                            isPresented: $isMintingNewCode,
                            titleVisibility: .visible) {
            Button(String(app: Strings.Recovery.newConfirm), role: .destructive) {
                Task { freshCode = await recovery.makeNewKey() }
            }
        } message: {
            Text(Strings.Recovery.newMessage)
        }
        .sheet(item: $freshCode) { code in
            // No "skip" here, unlike the setup flow: nobody arrives on this sheet by accident. They
            // pressed a button that says "make me a new code", and there is nothing to nag them
            // about afterwards that they have not just done on purpose.
            RecoveryCodeView(code: code.value, onSaved: { freshCode = nil })
        }
        // `Bindable`, not `$recovery` — the store is the session's now and is held as a plain `let`,
        // so there is no `@State` projection to reach through. Same as the room list does with its own.
        .failureAlert(Bindable(recovery).failure)
    }

    /// Where things stand, and the one button that changes it. Exactly one of these four is
    /// on screen at a time, and each carries its own way forward — there is no state here
    /// that is a dead end.
    @ViewBuilder
    private var state: some View {
        switch recovery.protection {
        case .unknown:
            Section {
                ProgressView()
                    .frame(maxWidth: .infinity)
            }

        case .on:
            Section {
                Label {
                    Text(Strings.Encryption.on)
                } icon: {
                    Image(systemName: "lock.shield.fill")
                        .foregroundStyle(.green)
                }
            } footer: {
                Text(Strings.Encryption.onHelp)
            }

        case .off:
            Section {
                Label {
                    Text(Strings.Encryption.off)
                } icon: {
                    Image(systemName: "exclamationmark.shield.fill")
                        .foregroundStyle(.orange)
                }

                Button {
                    Task { freshCode = await recovery.protectHistory() }
                } label: {
                    working(Strings.Encryption.protect)
                }
                .disabled(recovery.isWorking)
            } footer: {
                Text(Strings.Encryption.offHelp)
            }

        case .keyNeeded:
            Section {
                Label {
                    Text(Strings.Encryption.keyNeeded)
                } icon: {
                    Image(systemName: "key.slash.fill")
                        .foregroundStyle(.orange)
                }

                // A recovery key arrives by paste, out of a password manager, and it is not
                // a word anyone's keyboard should be helping with.
                TextField(String(app: Strings.Encryption.keyPlaceholder), text: $typedKey)
                    .textContentType(.password)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif

                Button {
                    Task {
                        await recovery.restore(with: typedKey)
                        typedKey = ""
                    }
                } label: {
                    working(Strings.Encryption.restore)
                }
                .disabled(recovery.isWorking || typedKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } footer: {
                Text(Strings.Encryption.keyNeededHelp)
            }
        }
    }

    /// This device, while the account does not yet trust it — and the way to make it.
    ///
    /// Drawn only then. Once it is verified there is nothing to do about it, and a green "Verified"
    /// row with the device's ID beside it was a fact nobody came to this screen for.
    ///
    /// The button is the point. For a long time it did not exist while the rest of the app
    /// cheerfully told people to come here and verify: a message that would not send said "verify
    /// this device — it's done in settings", and settings said "Not verified" and offered nothing.
    private var thisDevice: some View {
        Section {
            Label {
                Text(Strings.Encryption.deviceUnverified)
            } icon: {
                Image(systemName: "seal")
                    .foregroundStyle(.secondary)
            }

            Button {
                isVerifying = true
                Task { await verification.start() }
            } label: {
                working(Strings.Verification.verify, isWorking: verification.isWorking)
            }
            .disabled(verification.isWorking)
        } footer: {
            Text(Strings.Verification.why)
        }
    }

    /// Who else is in this account, and who is kept out of your conversations.
    ///
    /// The devices are the account's sessions, Telegram's "Devices" — only where there is a device
    /// ID to call this one by. Both rows used to sit on the settings root.
    private var people: some View {
        Section {
            if session.deviceID != nil {
                PushRow { page = .devices } label: {
                    Label(Strings.Devices.title, systemImage: "laptopcomputer.and.iphone")
                }
            }

            PushRow { page = .blocked } label: {
                Label(Strings.Settings.blocked, systemImage: "hand.raised")
            }

            bridge
        }
    }

    /// What other people learn about you without your writing anything: that you are here, and
    /// that you are typing — the two things a Matrix server actually tells others.
    @ViewBuilder
    private var privacy: some View {
        Section {
            Toggle(isOn: $hidesPresence) {
                Label(Strings.Privacy.hidePresence, systemImage: "clock.badge.xmark")
            }
            .accentControl()
        } header: {
            Text(Strings.Privacy.title)
        } footer: {
            Text(Strings.Privacy.hidePresenceHelp)
        }

        Section {
            Toggle(isOn: $hidesTyping) {
                Label(Strings.Privacy.hideTyping, systemImage: "ellipsis.bubble")
            }
            .accentControl()
        } footer: {
            Text(Strings.Privacy.hideTypingHelp)
        }
    }

    /// The app-lock controls: a switch, and — once it is on — how long a trip away is forgiven. The
    /// switch is `@Bindable` on the lock itself, so flipping it writes straight through to the store
    /// that persists it. When the device has no passcode of its own there is nothing to lean on, so
    /// the switch is disabled and says why.
    ///
    /// Moved here from the settings root. A lock on the app is a question about who can get at this
    /// account from this device, which is the question this screen is.
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

    /// Whether traffic goes through a bridge rather than straight at the homeserver — see
    /// `ConnectionView`, which spells out what a bridge can read and what the switch does not yet
    /// do for you.
    ///
    /// It belongs on this screen and not on the settings root, and the screen itself is the
    /// argument: two of its four sections exist to say who can see your traffic and how far the
    /// protection actually goes. That is a security question wearing the word "connection".
    ///
    /// A row under the devices and the blocked, in their group: all three are about who stands
    /// between you and the people you talk to.
    private var bridge: some View {
        PushRow { page = .connection } label: {
            Label(
                Strings.Settings.connection,
                systemImage: "point.3.filled.connected.trianglepath.dotted"
            )
        }
    }

    /// A button's label while the request behind it is in flight. Every act on this screen
    /// talks to the server, and enabling recovery uploads every room key this device holds
    /// — which on an old account is not a moment, it is a minute.
    @ViewBuilder
    private func working(_ title: LocalizedStringResource,
                         isWorking: Bool? = nil) -> some View {
        HStack(spacing: Theme.Spacing.close) {
            Text(title)
            if isWorking ?? recovery.isWorking {
                Spacer()
                ProgressView()
            }
        }
    }
}
