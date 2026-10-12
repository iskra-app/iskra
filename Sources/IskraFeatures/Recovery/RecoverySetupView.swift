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

    /// Called once, when there is nothing left to ask, and the root takes the app into the
    /// conversations.
    var onDone: () -> Void

    /// A way out, for the times this is a sheet somebody opened rather than a gate they must pass.
    ///
    /// It is not decoration, and leaving it off was a real trap: tapped from the banner, this screen
    /// had no exit at all except finishing one of the flows on it. Somebody who tapped the banner to
    /// see what it wanted was stuck with a choice between typing a code they did not have and
    /// destroying their encryption.
    ///
    /// `nil` on the way in from signing in, where there is genuinely nothing to go back *to* — the
    /// app is not behind this screen yet. Even then nobody is cornered: every branch ends in `.done`.
    var onCancel: (() -> Void)?

    @State private var isConfirming = false

    init(session: UserSession,
         onCancel: (() -> Void)? = nil,
         onDone: @escaping () -> Void) {
        _model = State(initialValue: RecoverySetupModel(session: session))
        self.onCancel = onCancel
        self.onDone = onDone
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.generous) {
                switch model.step {
                case .preparing:
                    waiting(Strings.Recovery.preparing)

                case .confirmNew:
                    confirmNew

                case .approving:
                    approving

                case .creating, .startingOver:
                    creating

                case .code:
                    if let code = model.code {
                        RecoveryCodeView(code: code.value, onSaved: model.savedCode)
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
        .scrollBounceBehavior(.basedOnSize)
        .animation(.smooth, value: model.step)
        // The way out, where there is one to offer — and only on the steps where walking away is
        // harmless. It is deliberately absent while the backup is being built or the identity thrown
        // away (a half-finished reset is not a thing to leave lying around), and absent on the code
        // itself, which is the one screen in the app that must be *read* rather than dismissed: the
        // code cannot be shown twice, so a code closed by reflex is a code that is gone.
        //
        // It is the system's close button and not a hand-drawn "×" any more. It used to be an `Image`
        // inside a `.plain` button with no label of any kind, which VoiceOver announces as "button":
        // the one control on the screen whose entire job is to be the way out, and it could not say
        // so. `role: .leaving` (`.close` from OS 26) buys the standard look, the standard placement and the standard label,
        // in every language, without this file naming any of them.
        .overlay(alignment: .topTrailing) {
            if let onCancel, canLeave {
                Button(role: .leaving, action: onCancel) {
                    Label(String(app: Strings.Recovery.close), systemImage: "xmark")
                        .labelStyle(.iconOnly)
                }
                .navigationGlassButton()
                .controlSize(.large)
                .padding(Theme.Spacing.close)
            }
        }
        .task { await model.begin() }
        .onChange(of: model.step) { _, step in
            guard step == .done else { return }
            onDone()
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
        case .choose, .entering, .lost, .password, .confirmNew: true
        // `.approving` has two answers of its own and needs neither a third nor a silent one: a
        // reset half-approved on the server is exactly the state not to walk away from.
        case .preparing, .creating, .startingOver, .code, .done, .approving: false
        }
    }

    // MARK: - The steps

    /// The question in front of every code this flow destroys.
    ///
    /// Reached after the user has proved this device against another one, having said they could not
    /// find their code. It used to mint on the spot — and the comparison does not touch the secret
    /// storage, so the old code was never dead until the app killed it. "Later" is a real answer here
    /// and not a courtesy: the history is already open, the account is in order, and the old code, if
    /// it turns up in a password manager tonight, still works.
    private var confirmNew: some View {
        VStack(spacing: Theme.Spacing.roomy) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundStyle(.orange)

            heading(Strings.Recovery.newTitle, Strings.Recovery.newMessage)

            Button {
                Task { await model.confirmNewCode() }
            } label: {
                busy(Strings.Recovery.newConfirm)
            }
            .buttonStyle(.glassAction)
            .controlSize(.large)
            .frame(maxWidth: .infinity)
            .disabled(model.isWorking)

            Button {
                model.keepOldCode()
            } label: {
                Text(Strings.Recovery.keepOldCode)
                    .font(.footnote)
                    .frame(maxWidth: .infinity, minHeight: Theme.Size.minimumTapTarget)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
    }

    /// The browser has closed, and the app has no idea what happened in it.
    ///
    /// It cannot have: the approval page redirects nowhere the app is listening, so
    /// `ASWebAuthenticationSession` reports the same thing whether the user approved and closed it or
    /// closed it instead of approving. Guessing is what the app used to do, and it guessed "approved"
    /// — which meant somebody who read what a reset costs and backed out got an error alert instead of
    /// the quiet nothing they had asked for.
    ///
    /// So it asks. Neither answer is styled as the easy one: on the other side of "Continue" is every
    /// message this account has ever received, and there is no undo.
    private var approving: some View {
        VStack(spacing: Theme.Spacing.roomy) {
            Image(systemName: "checkmark.shield")
                .font(.largeTitle)
                .foregroundStyle(.orange)

            heading(Strings.Recovery.approveTitle, Strings.Recovery.approveMessage)

            // Red, and labelled by its consequence — the two things that keep it from being pressed
            // by reflex. `.bordered` + `.tint(.red)` is the app's own destructive language, the same
            // pair the verification sheet uses for "It's not me"; the forbidden `.glassProminent`
            // would fill with the root tint and come back white. See `PrimaryActionStyle`.
            Button {
                Task { await model.approved() }
            } label: {
                busy(Strings.Recovery.approveConfirm)
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .controlSize(.large)
            .frame(maxWidth: .infinity)
            .disabled(model.isWorking)

            // The same size as the destructive one, not a footnote underneath it. When the two
            // answers are "erase everything" and "don't", the safe one must not be the smaller,
            // quieter target — the shape of the screen should not lean on the reader.
            Button {
                Task { await model.abandonStartOver() }
            } label: {
                Text(Strings.Recovery.approveCancel)
                    .frame(maxWidth: .infinity)
            }
            .navigationGlassButton()
            .controlSize(.large)
            .frame(maxWidth: .infinity)
        }
    }

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
    /// Both buttons are `.glass`, and **neither** is `.glassAction`. That is the one piece of
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
            .navigationGlassButton()
            .controlSize(.large)

            Button {
                isConfirming = true
                Task { await model.confirmFromAnotherDevice() }
            } label: {
                Text(Strings.Recovery.otherDevice)
                    .frame(maxWidth: .infinity)
            }
            .navigationGlassButton()
            .controlSize(.large)

            // The quiet third way out, for the person for whom neither of the two above is true. It
            // has to be here, and it has to be findable: without it this screen is a locked door.
            //
            // Quiet, and still 44pt tall — a `.plain` button is only as tall as its words, which for
            // a line of `.callout` is about 20. Being understated is a matter of colour and weight,
            // not of being difficult to hit.
            Button {
                Task { await model.lostTheCode() }
            } label: {
                Text(Strings.Recovery.neither)
                    .font(.footnote)
                    .frame(maxWidth: .infinity, minHeight: Theme.Size.minimumTapTarget)
                    .contentShape(.rect)
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
                .textContentType(.password)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .entryField()

            Button {
                Task { await model.unlock() }
            } label: {
                busy(Strings.Recovery.unlock)
            }
            .buttonStyle(.glassAction)
            .controlSize(.large)
            .frame(maxWidth: .infinity)
            .disabled(model.isWorking || model.typedCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Button {
                Task { await model.lostTheCode() }
            } label: {
                Text(Strings.Recovery.lostCode)
                    .font(.footnote)
                    .frame(maxWidth: .infinity, minHeight: Theme.Size.minimumTapTarget)
                    .contentShape(.rect)
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
                .buttonStyle(.glassAction)
                .controlSize(.large)
                .frame(maxWidth: .infinity)

                // The door that was not there, and whose absence made this screen a locked room.
                //
                // `hasOtherDevices` is the *account's* answer, and the account does not know that the
                // laptop was sold, that the other client will not open, or that the phone is at the
                // bottom of a lake. A person who had already said — on the previous screen, out loud,
                // by pressing "I have neither" — that they had no other device could land here and be
                // shown a single button reading "confirm from another device", with nothing else on
                // the screen. The app asked, was answered, and then insisted.
                Button {
                    model.noAccessToOtherDevice()
                } label: {
                    Text(Strings.Recovery.noAccessToOtherDevice)
                        .font(.footnote)
                        .frame(maxWidth: .infinity, minHeight: Theme.Size.minimumTapTarget)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
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
                .buttonStyle(.glassAction)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
                .disabled(model.isWorking)
            }
        }
    }

    private var password: some View {
        VStack(spacing: Theme.Spacing.roomy) {
            heading(Strings.Recovery.passwordTitle, Strings.Recovery.passwordMessage)

            SecureField(String(app: Strings.Recovery.passwordPlaceholder), text: $model.password)
                .entryField()

            Button {
                Task { await model.confirmWithPassword() }
            } label: {
                busy(Strings.Recovery.passwordConfirm)
            }
            .buttonStyle(.glassAction)
            .controlSize(.large)
            .frame(maxWidth: .infinity)
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
                .controlSize(.small)
                .frame(maxWidth: .infinity)
        } else {
            Text(title)
                .frame(maxWidth: .infinity)
        }
    }
}
