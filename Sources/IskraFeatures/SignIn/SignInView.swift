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

    /// Whether the visitor has asked for the password form on a server that also has OAuth.
    ///
    /// Only ever true because somebody said so out loud. It is not remembered between launches and
    /// it is not guessed at: the default is the way in that works for almost everybody, and the
    /// other one is a door you have to open.
    @State private var isUsingPassword = false

    /// - Parameters:
    ///   - authentication: who to sign in with. Only ever not the default under `--mock-signin`,
    ///     whose sessions must not land where the real account's do — see `MockSignIn`.
    ///   - address: what the field starts with.
    public init(authentication: AuthenticationService = AuthenticationService(),
                address: String = "",
                onSignedIn: @escaping @MainActor (UserSession) -> Void) {
        _model = State(initialValue: SignInModel(authentication: authentication,
                                                 address: address,
                                                 onSignedIn: onSignedIn))
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
                    problemPanel(problem)
                }
            }
            .padding(Theme.Spacing.generous)
            .frame(maxWidth: Theme.Size.signInColumn)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .animation(.smooth, value: model.step)
        .animation(.smooth, value: model.problem)
    }

    /// What went wrong, said so that somebody sees it.
    ///
    /// It used to be a line of grey text with a small outline icon beside it — the same colour,
    /// the same weight and very nearly the same size as the helper text under the field it was
    /// about. On a screen whose entire job is to say either "you are in" or "that did not work",
    /// the second answer was the quietest thing on it: people typed a wrong password, saw nothing
    /// change, and typed it again.
    ///
    /// So it is red, it is filled, it stands on a panel of its own, and it arrives from above
    /// rather than fading in — a thing that appears where nothing was is a thing the eye goes to.
    /// It is *not* glass and not a banner over the form: it is content, it is about the field
    /// directly above it, and it belongs in the layout beside it rather than floating over it.
    private func problemPanel(_ problem: LocalizedStringResource) -> some View {
        Label {
            Text(problem)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .font(.callout.weight(.medium))
        .foregroundStyle(.red)
        .multilineTextAlignment(.leading)
        .padding(Theme.Spacing.normal)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.bubble, style: .continuous)
            .fill(.red.opacity(Theme.Backdrop.wash)))
        .transition(.move(edge: .top).combined(with: .opacity))
        .accessibilityAddTraits(.isStaticText)
        // And *said*, rather than merely present.
        //
        // This carried a comment claiming `.isStaticText` announced it "the moment it appears".
        // It does not: a trait describes what an element is, and it makes VoiceOver say nothing at
        // all. So the panel arrived in silence, and a blind user got exactly the failure the long
        // comment above worries about for everybody else — type the password, nothing appears to
        // happen, type it again.
        //
        // An announcement is the one thing that does speak without being swiped onto, and this is
        // the moment it is for: something has gone wrong, the screen has not changed shape, and
        // the user is waiting to be told.
        .onAppear {
            AccessibilityNotification.Announcement(String(localized: problem)).post()
        }
    }

    private var header: some View {
        VStack(spacing: Theme.Spacing.normal) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: Theme.Size.signInMark))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            Text(Strings.SignIn.title)
                .font(.largeTitle.bold())

            Text(Strings.SignIn.tagline)
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .padding(.top, Theme.Spacing.generous)
    }

    private var addressForm: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.normal) {
            Text(Strings.SignIn.whereIsAccount)
                .font(.headline)

            Text(Strings.SignIn.whereIsAccountHelp)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField(String(app: Strings.SignIn.addressPlaceholder), text: $model.address)
                .textContentType(.URL)
                #if !os(macOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                #endif
                .autocorrectionDisabled()
                .focused($focus, equals: .address)
                .entryField()
                .onSubmit { Task { await model.findServer() } }
                .accessibilityLabel(Text(Strings.SignIn.addressLabel))

            Button {
                Task { await model.findServer() }
            } label: {
                busyLabel(Strings.SignIn.continue)
            }
            .buttonStyle(.glassAction)
            .controlSize(.large)
            .frame(maxWidth: .infinity)
            .disabled(!model.canContinue)
        }
        .onAppear { focus = .address }
    }

    /// How you get in, once the server has said how it lets people in.
    ///
    /// **One way in, not two.** This screen used to show the browser button and the password form
    /// together, separated by the word "or", each with a button of its own — and that is a screen
    /// handing the visitor a decision instead of a door. A server that speaks OAuth almost always
    /// accepts a password as well, so almost everybody was being asked to choose between two ways
    /// into the same account, on their first encounter with the app, on no information whatsoever.
    /// Nobody arrives wanting to pick an authentication method. They arrive wanting to be let in.
    ///
    /// So: where the server has OAuth, that *is* the way in, and the password form is behind a quiet
    /// sentence for the people who know they need it — and they do know; that is the whole character
    /// of the case. Where the server has no OAuth, there is no choice to hide and no cleverness
    /// required: it is a username, a password, and a button.
    @ViewBuilder
    private func signInForm(_ options: SignInOptions) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.roomy) {
            if options.canUseSingleSignOn {
                VStack(alignment: .leading, spacing: Theme.Spacing.close) {
                    Text(Strings.SignIn.readyTitle)
                        .font(.headline)
                    Text(Strings.SignIn.readyHelp)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Button {
                    Task { await model.continueWithSingleSignOn() }
                } label: {
                    busyLabel(Strings.SignIn.signIn)
                }
                .buttonStyle(.glassAction)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
                .disabled(model.isBusy)

                // Making an account, where the server says it can make one. Plain glass, not tinted:
                // most people arriving here already have an account and are here to sign in, and the
                // tinted button is spent on the thing the screen is actually about.
                //
                // Absent on servers that do not speak OIDC — not disabled, absent. There is no way to
                // register through this app on such a server at all, and a greyed-out button would be
                // the app implying otherwise.
                if options.supportsRegistration {
                    Button {
                        Task { await model.createAccount() }
                    } label: {
                        busyLabel(Strings.SignIn.createAccount)
                    }
                    .buttonStyle(.glass)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                    .disabled(model.isBusy)
                }

                if options.supportsPassword {
                    if isUsingPassword {
                        passwordFields
                        passwordButton(prominent: false)
                    } else {
                        Button(String(app: Strings.SignIn.usePasswordInstead)) {
                            isUsingPassword = true
                            focus = .username
                        }
                        .font(.footnote)
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                    }
                }
            } else if options.supportsPassword {
                // No OAuth, so nothing to hide behind anything: this is the way in, and it is the
                // only way in. No disclosure, no hint, no second thought.
                passwordFields
                passwordButton(prominent: true)
            }

            Button(String(app: Strings.SignIn.differentAddress)) {
                // The disclosure goes back with the address. It was a decision about *that* server,
                // and the next one may not even have a password to offer — arriving at it with the
                // form already open would be this screen remembering something that is not true any
                // more.
                isUsingPassword = false
                Task { await model.startOver() }
            }
            .font(.footnote)
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
        }
        .animation(.smooth, value: isUsingPassword)
    }

    private var passwordFields: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.normal) {
            TextField(String(app: Strings.SignIn.username), text: $model.username)
                .textContentType(.username)
                #if !os(macOS)
                .textInputAutocapitalization(.never)
                #endif
                .autocorrectionDisabled()
                .focused($focus, equals: .username)

            SecureField(String(app: Strings.SignIn.password), text: $model.password)
                .textContentType(.password)
                .focused($focus, equals: .password)
                .onSubmit { Task { await model.signInWithPassword() } }
        }
        .entryField()
    }

    /// Tinted only where it is the whole of the screen. Behind the browser button it is the fallback
    /// somebody went looking for, and tinted glass is spent on the one action a screen is about.
    @ViewBuilder
    private func passwordButton(prominent: Bool) -> some View {
        let button = Button {
            Task { await model.signInWithPassword() }
        } label: {
            busyLabel(prominent ? Strings.SignIn.signIn : Strings.SignIn.signInWithPassword)
        }
        .controlSize(.large)
        .frame(maxWidth: .infinity)
        .disabled(model.isBusy || model.username.isEmpty || model.password.isEmpty)

        if prominent {
            button.buttonStyle(.glassAction)
        } else {
            button.buttonStyle(.glass)
        }
    }

    @ViewBuilder
    private func busyLabel(_ title: LocalizedStringResource) -> some View {
        if model.isBusy {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity)
        } else {
            Text(title).frame(maxWidth: .infinity)
        }
    }
}
