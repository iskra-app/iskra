import SwiftUI
import IskraCore
import IskraDesign

/// The first thing anyone sees.
///
/// The copy here is doing real work. A person arriving at a Matrix client is
/// typically asked for a "homeserver URL", which is a sentence that means nothing to
/// them. Here they are asked nothing: two buttons — sign in, create an account — on a server
/// already filled in, and every protocol word kept off the screen. The address is one quiet
/// line for the people who were given one.
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
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: Theme.Spacing.generous) {
                    switch model.step {
                    case .enteringAddress:
                        door
                    case let .ready(options):
                        signInForm(options)
                    }
                }
                .padding(Theme.Spacing.generous)
                .frame(maxWidth: Theme.Size.signInColumn)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .animation(.smooth, value: model.step)
        .animation(.smooth, value: model.problem)
        .animation(.smooth, value: isEditingServer)
    }

    // MARK: - The door

    /// Whether the server line has been opened up into a field.
    @State private var isEditingServer = false

    /// The opening screen: the app, a sentence, and two buttons — the shape every messenger's first
    /// screen has, because it is the shape nobody needs explaining.
    ///
    /// It used to open on a question — "where is your account?" — over an empty field, which is a
    /// fair question to somebody who knows what a homeserver is and a wall to everybody else. Now
    /// the answer most people want, matrix.org, is already given, in one quiet line at the bottom
    /// with "Change" beside it. Somebody who was handed an address knows to press it; nobody else
    /// has to read it.
    private var door: some View {
        VStack(spacing: Theme.Spacing.generous) {
            Spacer(minLength: Theme.Spacing.generous)

            header

            Spacer(minLength: Theme.Spacing.generous)

            VStack(spacing: Theme.Spacing.normal) {
                if let problem = model.problem {
                    problemPanel(problem)
                }

                Button {
                    Task { await model.begin(.signIn) }
                } label: {
                    busyLabel(Strings.SignIn.signIn, when: model.pending == .signIn)
                }
                .buttonStyle(.glassAction)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
                .disabled(!model.canContinue)

                Button {
                    Task { await model.begin(.createAccount) }
                } label: {
                    busyLabel(Strings.SignIn.createAccount, when: model.pending == .createAccount)
                }
                .navigationGlassButton()
                .controlSize(.large)
                .frame(maxWidth: .infinity)
                .disabled(!model.canContinue)

                server
            }
        }
    }

    private var header: some View {
        VStack(spacing: Theme.Spacing.normal) {
            Group {
                if let artwork = AppIcon.artwork {
                    artwork
                        .resizable()
                        .scaledToFit()
                } else {
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                        .font(.system(size: Theme.Size.signInMark))
                        .foregroundStyle(.tint)
                }
            }
            .frame(width: Theme.Size.signInLogo, height: Theme.Size.signInLogo)
            .accessibilityHidden(true)

            Text(Strings.SignIn.title)
                .font(.largeTitle.bold())

            Text(Strings.SignIn.tagline)
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
    }

    /// Where the account will be: one line, or — once "Change" is pressed — the field for it.
    @ViewBuilder
    private var server: some View {
        if isEditingServer {
            VStack(alignment: .leading, spacing: Theme.Spacing.close) {
                Text(Strings.SignIn.whereIsAccount)
                    .font(.headline)

                Text(Strings.SignIn.whereIsAccountHelp)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: Theme.Spacing.close) {
                    TextField(String(app: Strings.SignIn.addressPlaceholder), text: $model.address)
                        .textContentType(.URL)
                        #if !os(macOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        #endif
                        .autocorrectionDisabled()
                        .focused($focus, equals: .address)
                        .submitLabel(.done)
                        .onSubmit { isEditingServer = false }
                        .entryField()
                        .accessibilityLabel(Text(Strings.SignIn.addressLabel))

                    Button(String(app: Strings.SignIn.serverDone)) {
                        isEditingServer = false
                    }
                    .font(.body.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                    .disabled(model.serverName.isEmpty)
                }
            }
            .padding(.top, Theme.Spacing.close)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
            .onAppear { focus = .address }
        } else {
            HStack(spacing: Theme.Spacing.tight) {
                Text(Strings.SignIn.server(model.serverName))
                    .foregroundStyle(.secondary)
                Button(String(app: Strings.SignIn.changeServer)) {
                    isEditingServer = true
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .disabled(model.isBusy)
            }
            .font(.footnote)
            .frame(maxWidth: .infinity)
            .padding(.top, Theme.Spacing.close)
        }
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
            Button {
                // The disclosure goes back with the address. It was a decision about *that* server,
                // and the next one may not even have a password to offer.
                isUsingPassword = false
                Task { await model.startOver() }
            } label: {
                Label(String(app: Strings.SignIn.back), systemImage: "chevron.backward")
                    .font(.body.weight(.medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
            .disabled(model.isBusy)

            Text(Strings.SignIn.signInTo(model.serverName))
                .font(.largeTitle.bold())
                .fixedSize(horizontal: false, vertical: true)

            if options.canUseSingleSignOn && !(isUsingPassword && options.supportsPassword) {
                // The browser was closed before it finished. The way back to it, said as what it
                // is, and the password for the people who came back on purpose.
                Text(Strings.SignIn.browserHelp)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    Task { await model.continueWithSingleSignOn() }
                } label: {
                    busyLabel(Strings.SignIn.continueInBrowser)
                }
                .buttonStyle(.glassAction)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
                .disabled(model.isBusy)

                if options.supportsPassword {
                    Button(String(app: Strings.SignIn.usePasswordInstead)) {
                        isUsingPassword = true
                        focus = .username
                    }
                    .font(.footnote)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                }
            } else if options.supportsPassword {
                Text(Strings.SignIn.passwordHelp)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                passwordFields
                passwordButton(prominent: true)
                    .onAppear { if focus == nil { focus = .username } }
            }

            if let problem = model.problem {
                problemPanel(problem)
            }

            Spacer(minLength: 0)
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
            button.navigationGlassButton()
        }
    }

    @ViewBuilder
    private func busyLabel(_ title: LocalizedStringResource, when spinning: Bool? = nil) -> some View {
        if spinning ?? model.isBusy {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity)
        } else {
            Text(title).frame(maxWidth: .infinity)
        }
    }
}
