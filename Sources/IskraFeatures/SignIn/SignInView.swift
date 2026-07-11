import SwiftUI
import IskraCore
import IskraDesign

/// The first thing anyone sees.
///
/// The copy here is doing real work. A person arriving at a Matrix client is
/// typically asked for a "homeserver URL", which is a sentence that means nothing to
/// them. We ask where their account lives, suggest the answer most people want, and
/// keep every protocol word off the screen.
public struct SignInView: View {
    @State private var model: SignInModel
    @FocusState private var focus: Field?

    private enum Field { case address, username, password }

    public init(onSignedIn: @escaping @MainActor (UserSession) -> Void) {
        _model = State(initialValue: SignInModel(onSignedIn: onSignedIn))
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.generous) {
                header

                switch model.step {
                case .enteringAddress:
                    addressForm
                case let .ready(options):
                    signInForm(options)
                }

                if let problem = model.problem {
                    Label(problem, systemImage: "exclamationmark.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        // Announced by VoiceOver the moment it appears, rather than
                        // sitting silently until someone swipes onto it.
                        .accessibilityAddTraits(.isStaticText)
                }
            }
            .padding(Theme.Spacing.generous)
            .frame(maxWidth: 420)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .animation(.smooth, value: model.step)
        .animation(.smooth, value: model.problem)
    }

    private var header: some View {
        VStack(spacing: Theme.Spacing.normal) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            Text("Welcome to Iskra")
                .font(.largeTitle.bold())

            Text("Private messages, on your terms.")
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .padding(.top, Theme.Spacing.generous)
    }

    private var addressForm: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.normal) {
            Text("Where's your account?")
                .font(.headline)

            Text("If someone gave you an address to use, type it here. If not, matrix.org works for most people.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("matrix.org", text: $model.address)
                .textFieldStyle(.plain)
                .textContentType(.URL)
                #if !os(macOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                #endif
                .autocorrectionDisabled()
                .focused($focus, equals: .address)
                .padding(Theme.Spacing.normal)
                .frame(minHeight: Theme.Size.minimumTapTarget)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                .onSubmit { Task { await model.findServer() } }
                .accessibilityLabel("Account address")

            Button {
                Task { await model.findServer() }
            } label: {
                busyLabel("Continue")
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .frame(maxWidth: .infinity)
            .disabled(!model.canContinue)
        }
        .onAppear { focus = .address }
    }

    @ViewBuilder
    private func signInForm(_ options: SignInOptions) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.roomy) {
            if options.canUseSingleSignOn {
                VStack(alignment: .leading, spacing: Theme.Spacing.close) {
                    Text("You're all set")
                        .font(.headline)
                    Text("We'll open your browser so you can sign in the usual way.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Button {
                    Task { await model.continueWithSingleSignOn() }
                } label: {
                    busyLabel("Sign in")
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
                .disabled(model.isBusy)
            }

            if options.canUseSingleSignOn && options.supportsPassword {
                Text("or")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
            }

            if options.supportsPassword {
                VStack(alignment: .leading, spacing: Theme.Spacing.normal) {
                    TextField("Username", text: $model.username)
                        .textContentType(.username)
                        #if !os(macOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                        .focused($focus, equals: .username)

                    SecureField("Password", text: $model.password)
                        .textContentType(.password)
                        .focused($focus, equals: .password)
                        .onSubmit { Task { await model.signInWithPassword() } }
                }
                .textFieldStyle(.plain)
                .padding(Theme.Spacing.normal)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))

                // When SSO is also on offer, the password button is the secondary
                // path, so it gets plain glass. Tinted glass is reserved for the one
                // action the screen is actually about.
                let passwordButton = Button {
                    Task { await model.signInWithPassword() }
                } label: {
                    busyLabel(options.canUseSingleSignOn ? "Sign in with a password" : "Sign in")
                }
                .controlSize(.large)
                .frame(maxWidth: .infinity)
                .disabled(model.isBusy || model.username.isEmpty || model.password.isEmpty)

                if options.canUseSingleSignOn {
                    passwordButton.buttonStyle(.glass)
                } else {
                    passwordButton.buttonStyle(.glassProminent)
                }
            }

            Button("Use a different address") {
                Task { await model.startOver() }
            }
            .font(.footnote)
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private func busyLabel(_ title: String) -> some View {
        if model.isBusy {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity)
        } else {
            Text(title).frame(maxWidth: .infinity)
        }
    }
}
