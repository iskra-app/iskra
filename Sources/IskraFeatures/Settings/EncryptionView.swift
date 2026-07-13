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
    @State private var recovery: RecoveryStore

    /// The one true thing this screen can say about sessions — see the footer, and
    /// `ROADMAP.md`, stage 6.
    let deviceID: String

    /// What is being typed into the field, when the key is being typed rather than made.
    @State private var typedKey = ""
    @State private var hasCopied = false

    init(recovery: RecoveryStore, deviceID: String) {
        _recovery = State(initialValue: recovery)
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
                        Label(String(app: Strings.Encryption.newKey), systemImage: "key")
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
        .onAppear { recovery.load() }
        .onDisappear { recovery.stop() }
        // Presented from the root of the screen rather than from the row that produces the
        // key: the row is inside a `Section` that stops being drawn the moment `protection`
        // flips to `.on`, and a sheet attached to a view that has just been removed never
        // opens. The key would then be minted, held, and shown to nobody.
        .sheet(isPresented: Binding(get: { recovery.freshKey != nil },
                                    set: { if !$0 { recovery.forgetFreshKey() } })) {
            if let key = recovery.freshKey {
                KeySheet(key: key, hasCopied: $hasCopied) {
                    recovery.forgetFreshKey()
                    hasCopied = false
                }
            }
        }
        .alert(Text(Strings.Room.Manage.failedTitle),
               isPresented: Binding(get: { recovery.failure != nil },
                                    set: { if !$0 { recovery.failure = nil } }),
               presenting: recovery.failure) { _ in
            Button(String(app: Strings.Room.ok)) { recovery.failure = nil }
        } message: { failure in
            Text(failure.explanation)
        }
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
            LabeledContent {
                Text(deviceID)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
            } label: {
                Text(Strings.Encryption.thisDevice)
            }

            Label {
                Text(recovery.isDeviceVerified
                     ? Strings.Encryption.deviceVerified
                     : Strings.Encryption.deviceUnverified)
            } icon: {
                Image(systemName: recovery.isDeviceVerified ? "checkmark.seal.fill" : "seal")
                    .foregroundStyle(recovery.isDeviceVerified ? .green : .secondary)
            }
        } footer: {
            Text(Strings.Encryption.otherDevices)
        }
    }

    /// A button's label while the request behind it is in flight. Every act on this screen
    /// talks to the server, and enabling recovery uploads every room key this device holds
    /// — which on an old account is not a moment, it is a minute.
    @ViewBuilder
    private func working(_ title: LocalizedStringResource) -> some View {
        HStack(spacing: Theme.Spacing.close) {
            Text(title)
            if recovery.isWorking {
                Spacer()
                ProgressView()
            }
        }
    }
}

/// The recovery key, the once.
///
/// No swipe-to-dismiss and no close button: the only way out is the button that says the
/// key has been saved, because every other way out is a way to lose it by accident. The
/// sheet is not asking the user to agree to anything — it is making them look.
private struct KeySheet: View {
    let key: String
    @Binding var hasCopied: Bool
    var onDone: () -> Void

    var body: some View {
        VStack(spacing: Theme.Spacing.roomy) {
            Image(systemName: "key.horizontal.fill")
                .font(.largeTitle)
                .foregroundStyle(.orange)

            Text(Strings.Encryption.saveKey)
                .font(.title2.weight(.semibold))

            Text(Strings.Encryption.saveKeyHelp)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            // Monospaced and selectable: this is a string somebody is going to compare
            // character by character one day, in a bad mood.
            Text(key)
                .font(.body.monospaced())
                .textSelection(.enabled)
                .multilineTextAlignment(.center)
                .padding(Theme.Spacing.roomy)
                .frame(maxWidth: .infinity)
                .background(.fill.tertiary, in: .rect(cornerRadius: Theme.Radius.card, style: .continuous))

            Button {
                copy()
            } label: {
                Label(String(app: hasCopied ? Strings.Encryption.keyCopied : Strings.Encryption.copyKey),
                      systemImage: hasCopied ? "checkmark" : "doc.on.doc")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            Button(action: onDone) {
                Text(Strings.Encryption.saved)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(Theme.Spacing.generous)
        .frame(maxWidth: Theme.Size.keySheet)
        .interactiveDismissDisabled()
    }

    private func copy() {
        #if os(iOS)
        UIPasteboard.general.string = key
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(key, forType: .string)
        #endif
        hasCopied = true
    }
}
