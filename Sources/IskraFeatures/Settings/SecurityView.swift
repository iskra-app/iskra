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
/// Three more things were asking halves of the same question from three separate rows on the
/// settings root — the other devices signed into this account, the Face ID lock on the app, and
/// whether traffic goes through a bridge that can see it. Scattered, each read as a small
/// preference; gathered here, under a name that covers them, they read as one subject. So the
/// screen has five sections and one heading, and the heading is "Security".
///
/// The recovery key itself is shown exactly once, in a sheet with no way to dismiss it except the
/// button that says the user has saved it. That is not an interaction pattern anyone enjoys,
/// and it is the correct one: a recovery key the user swiped away is a recovery key they do
/// not have, and they find that out months later, from a screen that cannot help them.
struct SecurityView: View {
    /// The session, which this screen needs for two of the things it has taken in: the bridge
    /// screen is built over it, and the address of the account's own devices page is asked of it.
    let session: UserSession

    /// The app lock, put up by the root. Nil only where the root has not — never in the real app.
    /// It used to be read by `SettingsView`, which drew the switch itself.
    @Environment(\.appLock) private var appLock

    /// Where this account's devices are managed — on the server's own page, because there is
    /// nowhere in this app they could be. Resolved once, on appearance; `nil` means the session
    /// did not come through OAuth and there is no such page, and then the row is not drawn at all.
    ///
    /// Resolved *here* now rather than being handed down from settings. The row and the sentence
    /// in `otherDevices` that depends on whether the row exists are on the same screen at last, so
    /// the fact does not have to travel between two of them.
    @State private var devicesURL: URL?

    /// The session's, not this screen's — a plain `let`, exactly like `verification` below.
    ///
    /// It used to be built by this screen and torn down with it, which was fine while this screen was
    /// the only thing that asked. It is not: the room list carries a banner about a recovery code
    /// that was never saved, and a banner cannot ask a question that only settings knows the answer
    /// to. State that everything needs cannot belong to one screen.
    let recovery: RecoveryStore

    /// The one true thing this screen can say about sessions — see the footer, and
    /// `ROADMAP.md`, stage 6. Optional because a client with no device ID is a thing to say
    /// nothing about rather than an empty line under a heading.
    let deviceID: String?

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
         verification: VerificationStore,
         deviceID: String?) {
        self.session = session
        self.recovery = recovery
        self.verification = verification
        self.deviceID = deviceID
    }

    var body: some View {
        Form {
            state

            if recovery.protection == .on {
                Section {
                    // Asks first. Minting a code destroys the one before it, permanently and with no
                    // undo, and this row used to do that on a single tap — as did the room-list
                    // banner, which is how a real recovery code was lost. The footer already said the
                    // old code would stop working; a footer is not a question, and people press
                    // buttons without reading footers. Settings is the only place a code is minted
                    // deliberately now, so this dialog is the only place the question is asked.
                    Button {
                        isMintingNewCode = true
                    } label: {
                        working(Strings.Encryption.newKey)
                    }
                    .disabled(recovery.isWorking)
                } footer: {
                    Text(Strings.Encryption.newKeyHelp)
                }
            }

            thisDevice

            otherDevicesSection

            if let appLock {
                lockSection(appLock)
            }

            bridge
        }
        .formStyle(.grouped)
        .navigationTitle(Text(Strings.Settings.security))
        .toolbarTitleDisplayMode(.inline)
        // Cheap: the SDK builds this out of OAuth metadata it has already cached, without going to
        // the network. It is still async, so it cannot be read straight out of `body`.
        .task { devicesURL = await session.deviceManagementURL() }
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

    /// This device, named the way the account names it, and whether the account trusts it.
    ///
    /// One device, not a list, and the footer says why rather than leaving a suspiciously
    /// short list to speak for itself.
    private var thisDevice: some View {
        Section {
            if let deviceID {
                LabeledContent {
                    Text(deviceID)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                } label: {
                    Text(Strings.Encryption.thisDevice)
                }
            }

            Label {
                Text(recovery.isDeviceVerified
                     ? Strings.Encryption.deviceVerified
                     : Strings.Encryption.deviceUnverified)
            } icon: {
                Image(systemName: recovery.isDeviceVerified ? "checkmark.seal.fill" : "seal")
                    .foregroundStyle(recovery.isDeviceVerified ? .green : .secondary)
            }

            // And, if it is not verified, the way to verify it — which for a long time did not
            // exist while the rest of the app cheerfully told people to come here and do it. A
            // message that would not send said "verify this device — it's done in settings", and
            // settings said "Not verified" and offered nothing. The instruction led to a wall.
            if !recovery.isDeviceVerified {
                Button {
                    isVerifying = true
                    Task { await verification.start() }
                } label: {
                    working(Strings.Verification.verify, isWorking: verification.isWorking)
                }
                .disabled(verification.isWorking)
            }
        } footer: {
            Text(otherDevices)
        }
    }

    /// The sentence under this device, once it is trusted and there is nothing left to do about it.
    ///
    /// Which of two sentences it is depends on whether the "My devices" row below exists, because
    /// it used to simply assert that it did — and on a session signed in with a password there is
    /// no such row, so the app was citing a section of its own settings that was not there. The row
    /// only appears where the server hands over an account page, which it only does for a session
    /// obtained through the browser; everywhere else the honest answer is the older one, which is
    /// that the other devices are the server's business and not ours.
    private var otherDevices: LocalizedStringResource {
        guard recovery.isDeviceVerified else { return Strings.Verification.why }
        return devicesURL != nil ? Strings.Encryption.otherDevicesHere
                                 : Strings.Encryption.otherDevices
    }

    /// The devices, which live somewhere else — and the row is only here when there is somewhere
    /// else for it to lead to.
    ///
    /// There is no native list and there is not going to be one. The Rust SDK has `devices()` and
    /// `delete_devices()`; the FFI deliberately exports neither, and on a homeserver running the
    /// authentication service the endpoint that deletes a device answers 404 — it is gone, not
    /// guarded. What the SDK *does* hand over is the address of the page that can do it, opened
    /// with the session the user already has, which is Element X's answer to the same wall.
    ///
    /// `deviceManagementURL()` is nil when the session was not obtained through OAuth, and then
    /// this section simply is not drawn. A row that led nowhere would be worse than no row: it
    /// would be the app claiming it could do something it cannot.
    ///
    /// It sat on the settings root until now, one section above a section about encryption, which
    /// put "this device" and "my other devices" on two different screens.
    @ViewBuilder
    private var otherDevicesSection: some View {
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
    private var bridge: some View {
        Section {
            NavigationLink {
                ConnectionView(session: session)
            } label: {
                Label(
                    Strings.Settings.connection,
                    systemImage: "point.3.filled.connected.trianglepath.dotted"
                )
            }
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
