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
    /// `ROADMAP.md`, stage 6. Optional because a client with no device ID is a thing to say
    /// nothing about rather than an empty line under a heading.
    let deviceID: String?

    /// What is being typed into the field, when the key is being typed rather than made.
    @State private var typedKey = ""

    /// Proving this device is yours. Built by the session, held here for as long as the screen is,
    /// and taken down with it — the SDK's controller carries a delegate registration, and a screen
    /// that made a fresh one on every redraw would leave a trail of them.
    @State private var verification: VerificationStore

    @State private var isVerifying = false

    init(recovery: RecoveryStore, verification: VerificationStore, deviceID: String?) {
        _recovery = State(initialValue: recovery)
        _verification = State(initialValue: verification)
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
        .onAppear { recovery.load() }
        .onDisappear {
            recovery.stop()
            verification.stop()
        }
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
            KeySheet(key: key.value, onDone: recovery.forgetFreshKey)
        }
        .failureAlert($recovery.failure)
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

/// The recovery key, the once.
///
/// No swipe-to-dismiss and no close button: the only way out is the button that says the
/// key has been saved, because every other way out is a way to lose it by accident. The
/// sheet is not asking the user to agree to anything — it is making them look.
private struct KeySheet: View {
    let key: String
    var onDone: () -> Void

    /// Local, because nobody outside this sheet reads it. SwiftUI rebuilds the sheet's
    /// content on each presentation, so it starts out false without anybody resetting it.
    @State private var hasCopied = false

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
        // The *secret* path, not the ordinary one. See `Clipboard.copySecret`: this string is the
        // password to every message the account has ever received, and the general pasteboard
        // syncs to every other device on the Apple ID and keeps what it is given indefinitely.
        Clipboard.copySecret(key)
        hasCopied = true
    }
}

/// Comparing seven pictures with a device that is already trusted.
///
/// The whole security of this rests on the user *looking*, so the screen is built to make looking
/// the easy thing and agreeing the deliberate one. The pictures are large. The two answers sit
/// side by side and neither is styled as the obvious one — a prominent "They match" beside a
/// quiet "They don't" would be the app nudging somebody towards the answer that grants trust,
/// which is precisely the answer an attacker in the middle needs them to give.
///
/// What the pictures *are* is the SDK's business and stays there: they come out of a secret the two
/// devices worked out between them, and a third device that is not in the conversation cannot
/// produce the same seven. No cryptography is performed here. This is a list and two buttons.
private struct VerificationSheet: View {
    let verification: VerificationStore
    let onDone: () -> Void

    @Environment(\.accent) private var accent

    var body: some View {
        NavigationStack {
            Group {
                switch verification.step {
                case .idle, .waitingForOtherDevice:
                    waiting

                case let .comparing(symbols):
                    comparing(symbols)

                case .succeeded:
                    outcome(systemImage: "checkmark.seal.fill",
                            tint: .green,
                            title: Strings.Verification.doneTitle,
                            message: Strings.Verification.doneMessage)

                case .declined:
                    outcome(systemImage: "exclamationmark.triangle.fill",
                            tint: .orange,
                            title: Strings.Verification.declinedTitle,
                            message: Strings.Verification.declinedMessage)

                case .failed:
                    outcome(systemImage: "xmark.circle.fill",
                            tint: .secondary,
                            title: Strings.Verification.failedTitle,
                            message: Strings.Verification.failedMessage)
                }
            }
            .navigationTitle(Text(Strings.Verification.title))
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(app: Strings.Verification.close)) {
                        Task {
                            await verification.cancel()
                            onDone()
                        }
                    }
                }
            }
        }
    }

    /// Nothing to do but wait for somebody to notice on the other device — and to be told, plainly,
    /// what "the other device" means. A person with one phone cannot do this at all, and the screen
    /// says so rather than spinning at them forever.
    private var waiting: some View {
        ContentUnavailableView {
            Label(Strings.Verification.waitingTitle, systemImage: "iphone.and.arrow.forward")
        } description: {
            Text(Strings.Verification.waitingMessage)
        } actions: {
            ProgressView()
        }
    }

    private func comparing(_ symbols: [String]) -> some View {
        VStack(spacing: Theme.Spacing.generous) {
            Text(Strings.Verification.compare)
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, Theme.Spacing.generous)

            // Wrapped rather than in one row: seven emoji at a size worth looking at do not fit
            // across a phone, and shrinking them to make them fit would be defeating the purpose of
            // the screen to preserve its layout.
            FlowLayout(spacing: Theme.Spacing.roomy) {
                ForEach(Array(symbols.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol)
                        .font(.system(size: Theme.Size.verificationEmoji))
                }
            }
            .padding(.horizontal, Theme.Spacing.generous)
            // One element to VoiceOver, reading the seven in order: a screen reader user compares
            // them by hearing them, and seven separate stops with no context is not a comparison.
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(symbols.joined(separator: ", ")))

            Spacer()

            // Neither answer is the prominent one. See the note on the type.
            HStack(spacing: Theme.Spacing.normal) {
                Button {
                    Task { await verification.decline() }
                } label: {
                    Text(Strings.Verification.noMatch)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    Task { await verification.approve() }
                } label: {
                    Text(Strings.Verification.match)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(accent.color)
            }
            .controlSize(.large)
            .disabled(verification.isWorking)
            .padding(.horizontal, Theme.Spacing.generous)
            .padding(.bottom, Theme.Spacing.generous)
        }
        .padding(.top, Theme.Spacing.generous)
    }

    private func outcome(systemImage: String,
                         tint: Color,
                         title: LocalizedStringResource,
                         message: LocalizedStringResource) -> some View {
        ContentUnavailableView {
            Label {
                Text(title)
            } icon: {
                Image(systemName: systemImage)
                    .foregroundStyle(tint)
            }
        } description: {
            Text(message)
        } actions: {
            Button(String(app: Strings.Verification.close), action: onDone)
                .buttonStyle(.borderedProminent)
        }
    }
}
