import SwiftUI
import IskraCore
import IskraDesign

/// The screen between signing in and the conversations. See `RecoverySetupModel` for why it exists
/// at all, and what each of its steps means.
///
/// It is laid out like the sign-in screen it follows — one column, centred, capped at a readable
/// width — because to the person using it this is still part of getting in, and a screen that
/// changed its manners halfway through would read as a different app.
struct RecoverySetupView: View {
    @State private var model: RecoverySetupModel

    /// Called once, when there is nothing left to ask. The root takes the app into the conversations
    /// and carries `didSkipSavingCode` with it, so the room list knows whether to nag.
    var onDone: (Bool) -> Void

    /// A way out, for the times this is a sheet somebody opened rather than a gate they must pass.
    ///
    /// It is not decoration, and leaving it off was a real trap: tapped from the banner, this screen
    /// had no exit at all except finishing one of the flows on it. Somebody who tapped the banner to
    /// see what it wanted was stuck with a choice between typing a code they did not have and
    /// destroying their encryption.
    ///
    /// `nil` on the way in from signing in, where there is genuinely nothing to go back *to* — the
    /// app is not behind this screen yet. Even then nobody is cornered: every branch ends in `.done`,
    /// and skipping the code is a button.
    var onCancel: (() -> Void)?

    @State private var isConfirming = false

    init(session: UserSession,
         entry: RecoverySetupModel.Entry = .afterSignIn,
         onCancel: (() -> Void)? = nil,
         onDone: @escaping (Bool) -> Void) {
        _model = State(initialValue: RecoverySetupModel(session: session, entry: entry))
        self.onCancel = onCancel
        self.onDone = onDone
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.generous) {
                switch model.step {
                case .preparing:
                    waiting(Strings.Recovery.preparing)

                case .creating, .startingOver:
                    creating

                case .code:
                    if let code = model.code {
                        RecoveryCodeView(code: code.value,
                                         onSaved: model.savedCode,
                                         onSkip: model.skippedCode)
                    }

                case .choose:
                    choose

                case .entering:
                    entering

                case .lost:
                    lost

                case .password:
                    password

                case .done:
                    // Nothing is drawn: the `.onChange` below has already taken the app onward, and
                    // a spinner here would flash for one frame on the way out.
                    Color.clear
                }
            }
            .frame(maxWidth: Theme.Size.signInColumn)
            .frame(maxWidth: .infinity)
            .padding(Theme.Spacing.generous)
        }
        .animation(.smooth, value: model.step)
        // The way out, where there is one to offer — and only on the steps where walking away is
        // harmless. It is deliberately absent while the backup is being built or the identity thrown
        // away (a half-finished reset is not a thing to leave lying around), and absent on the code
        // itself, which is the one screen in the app that must be *read* rather than dismissed: the
        // code cannot be shown twice, so a code closed by reflex is a code that is gone.
        .overlay(alignment: .topTrailing) {
            if let onCancel, canLeave {
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: Theme.Size.minimumTapTarget,
                               height: Theme.Size.minimumTapTarget)
                }
                .buttonStyle(.plain)
                .padding(Theme.Spacing.close)
            }
        }
        .task { await model.begin() }
        .onChange(of: model.step) { _, step in
            guard step == .done else { return }
            onDone(model.didSkipSavingCode)
        }
        // The picture-comparison sheet, exactly the one the settings screen puts up and exactly the
        // one that answers an incoming request at the root. It was written to work in both directions
        // and it does; there is no second copy of it here.
        .sheet(isPresented: $isConfirming) {
            VerificationSheet(verification: model.verification) {
                isConfirming = false
                model.verification.reset()
            }
        }
        // Confirming succeeded — and what that *means* depends on where it was started from, which is
        // the model's business and not this view's. See `RecoverySetupModel.confirmed`.
        .onChange(of: model.verification.step) { _, step in
            guard step == .succeeded else { return }
            Task {
                isConfirming = false
                model.verification.reset()
                await model.confirmed()
            }
        }
        .failureAlert($model.failure)
    }

    /// Whether this is a moment the user may simply walk away from.
    ///
    /// `.creating` and `.startingOver` are requests in flight, and `.code` is the once-only sight of
    /// something that cannot be shown again. The rest are questions, and a question may be ignored.
    private var canLeave: Bool {
        switch model.step {
        case .choose, .entering, .lost, .password: true
        case .preparing, .creating, .startingOver, .code, .done: false
        }
    }

    // MARK: - The steps

    private func waiting(_ message: LocalizedStringResource) -> some View {
        VStack(spacing: Theme.Spacing.roomy) {
            ProgressView()
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, Theme.Spacing.generous)
    }

    /// Turning the backup on, or throwing the old one away. Both are slow — enabling recovery carries
    /// every room key this device holds up to the server — and both say so, because a minute under a
    /// silent spinner is a minute spent wondering whether the app has died.
    private var creating: some View {
        VStack(spacing: Theme.Spacing.roomy) {
            ProgressView()

            Text(Strings.Recovery.creatingTitle)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)

            Text(Strings.Recovery.creatingMessage)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, Theme.Spacing.generous)
    }

    /// The two ways in.
    ///
    /// Both buttons are `.glass`, and **neither** is `.glassProminent`. That is the one piece of
    /// styling in this file that is a decision rather than a default: making the code the prominent
    /// button would quietly tell everyone that comparing pictures is the lesser option, and the whole
    /// design of this flow is that it is not.
    private var choose: some View {
        VStack(spacing: Theme.Spacing.roomy) {
            heading(Strings.Recovery.chooseTitle, Strings.Recovery.chooseMessage)

            Button {
                model.chooseCode()
            } label: {
                Text(Strings.Recovery.haveCode)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)

            Button {
                isConfirming = true
                Task { await model.confirmFromAnotherDevice() }
            } label: {
                Text(Strings.Recovery.otherDevice)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)

            // The quiet third way out, for the person for whom neither of the two above is true. It
            // has to be here, and it has to be findable: without it this screen is a locked door.
            Button {
                Task { await model.lostTheCode() }
            } label: {
                Text(Strings.Recovery.neither)
                    .font(.callout)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.top, Theme.Spacing.close)
        }
    }

    private var entering: some View {
        VStack(spacing: Theme.Spacing.roomy) {
            heading(Strings.Recovery.enterTitle, Strings.Recovery.enterMessage)

            // A recovery code arrives by paste, out of a password manager, and it is not a word
            // anyone's keyboard should be helping with.
            TextField(String(app: Strings.Encryption.keyPlaceholder), text: $model.typedCode)
                .textFieldStyle(.roundedBorder)
                .textContentType(.password)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif

            Button {
                Task { await model.unlock() }
            } label: {
                busy(Strings.Recovery.unlock)
            }
            .buttonStyle(.glassProminent)
            .disabled(model.isWorking || model.typedCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Button {
                Task { await model.lostTheCode() }
            } label: {
                Text(Strings.Recovery.lostCode)
                    .font(.callout)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
    }

    /// The code is gone, and what can be done about it depends entirely on whether anything else on
    /// this account is still trusted. Two different screens, and they are not two shades of the same
    /// message: one is "no problem", the other is "this is a real loss, here is exactly what it costs".
    @ViewBuilder
    private var lost: some View {
        if model.hasOtherDevices {
            VStack(spacing: Theme.Spacing.roomy) {
                heading(Strings.Recovery.lostTitle, Strings.Recovery.lostHasDevices)

                Button {
                    isConfirming = true
                    Task { await model.recoverWithAnotherDevice() }
                } label: {
                    Text(Strings.Recovery.otherDevice)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
            }
        } else {
            VStack(spacing: Theme.Spacing.roomy) {
                heading(Strings.Recovery.aloneTitle, Strings.Recovery.aloneMessage)

                // The sentence that keeps a password reset and a lost recovery code apart. It is here
                // because somebody standing on this screen is *about* to go and reset their password
                // in the belief that it will bring their messages back, and it will not.
                Text(Strings.Recovery.notPassword)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Button {
                    Task { await model.startOver() }
                } label: {
                    busy(Strings.Recovery.startOver)
                }
                .buttonStyle(.glassProminent)
                .disabled(model.isWorking)
            }
        }
    }

    private var password: some View {
        VStack(spacing: Theme.Spacing.roomy) {
            heading(Strings.Recovery.passwordTitle, Strings.Recovery.passwordMessage)

            SecureField(String(app: Strings.Recovery.passwordPlaceholder), text: $model.password)
                .textFieldStyle(.roundedBorder)

            Button {
                Task { await model.confirmWithPassword() }
            } label: {
                busy(Strings.Recovery.passwordConfirm)
            }
            .buttonStyle(.glassProminent)
            .disabled(model.isWorking || model.password.isEmpty)
        }
    }

    // MARK: - Pieces

    private func heading(_ title: LocalizedStringResource,
                         _ message: LocalizedStringResource) -> some View {
        VStack(spacing: Theme.Spacing.close) {
            Text(title)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)

            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    /// A button's label while the request behind it is in flight. Everything on this screen talks to
    /// the server, and none of it is instant.
    @ViewBuilder
    private func busy(_ title: LocalizedStringResource) -> some View {
        if model.isWorking {
            ProgressView()
                .frame(maxWidth: .infinity)
        } else {
            Text(title)
                .frame(maxWidth: .infinity)
        }
    }
}
