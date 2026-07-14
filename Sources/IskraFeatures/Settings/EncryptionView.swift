import SwiftUI
import IskraCore
import IskraDesign

/// Whether this account's messages survive this device — and the two things that can be
/// done about it.
///
/// The screen answers one question, and it is not "is end-to-end encryption enabled": in
/// this app it always is, in every private room, and there is no switch for it. The question
/// is the one people actually discover the hard way, on the day they get a new phone: *will
/// I still be able to read any of this?* Everything here is written around that, which is
/// why the state is called `HistoryProtection` and not `RecoveryState`, and why the word
/// "key" only appears where the user has to physically handle one.
///
/// The key itself is shown exactly once, in a sheet with no way to dismiss it except the
/// button that says the user has saved it. That is not an interaction pattern anyone enjoys,
/// and it is the correct one: a recovery key the user swiped away is a recovery key they do
/// not have, and they find that out months later, from a screen that cannot help them.
struct EncryptionView: View {
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

    init(recovery: RecoveryStore, verification: VerificationStore, deviceID: String?) {
        self.recovery = recovery
        self.verification = verification
        self.deviceID = deviceID
    }

    var body: some View {
        Form {
            state

            if recovery.protection == .on {
                Section {
                    Button {
                        Task { await recovery.makeNewKey() }
                    } label: {
                        working(Strings.Encryption.newKey)
                    }
                    .disabled(recovery.isWorking)
                } footer: {
                    Text(Strings.Encryption.newKeyHelp)
                }
            }

            thisDevice
        }
        .formStyle(.grouped)
        .navigationTitle(Text(Strings.Encryption.title))
        .toolbarTitleDisplayMode(.inline)
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
        // key: the row is inside a `Section` that stops being drawn the moment `protection`
        // flips to `.on`, and a sheet attached to a view that has just been removed never
        // opens. The key would then be minted, held, and shown to nobody.
        //
        // `item:` rather than `isPresented:` — the key's presence *is* the presentation
        // state, so there is nothing to keep in step and nothing to unwrap twice.
        .sheet(item: Binding(get: { recovery.freshKey },
                             set: { if $0 == nil { recovery.forgetFreshKey() } })) { key in
            // No "skip" here, unlike the setup flow: nobody arrives on this sheet by accident. They
            // pressed a button that says "make me a new code", and there is nothing to nag them
            // about afterwards that they have not just done on purpose.
            RecoveryCodeView(code: key.value, onSaved: recovery.forgetFreshKey)
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
                    Task { await recovery.protectHistory() }
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
            Text(recovery.isDeviceVerified ? Strings.Encryption.otherDevices
                                           : Strings.Verification.why)
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
