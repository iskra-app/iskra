import SwiftUI
import IskraCore
import IskraDesign

/// Comparing seven pictures with a device on the other side — whichever side asked.
///
/// One sheet serves both directions, because after the first question they are the same
/// conversation: the pictures appear, a person looks at them, and a person answers. What differs is
/// only how it begins. Outgoing, it begins on the encryption screen with a button. Incoming, it
/// begins by *arriving* — so this sheet is also presented from the root of the app, over whatever
/// the user happened to be doing, and the first thing it shows is the name of the device that is
/// asking.
///
/// The whole security of this rests on the user *looking*, so the screen is built to make looking
/// the easy thing and agreeing the deliberate one. The pictures are large. The two answers sit
/// side by side and neither is styled as the obvious one — a prominent "They match" beside a
/// quiet "They don't" would be the app nudging somebody towards the answer that grants trust,
/// which is precisely the answer an attacker in the middle needs them to give. The same is true of
/// the question that opens the incoming flow, and for the same reason.
///
/// What the pictures *are* is the SDK's business and stays there: they come out of a secret the two
/// devices worked out between them, and a third device that is not in the conversation cannot
/// produce the same seven. No cryptography is performed here. This is a list and two buttons.
struct VerificationSheet: View {
    let verification: VerificationStore

    /// The sheet is closing. What that means depends on who put it up — the encryption screen has
    /// its own flag to lower, the root has only the store — so it is the caller's to say.
    let onDone: () -> Void

    @Environment(\.accent) private var accent

    var body: some View {
        NavigationStack {
            Group {
                switch verification.step {
                case .asked:
                    asked

                case .negotiating:
                    negotiating

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

                case .refused:
                    outcome(systemImage: "exclamationmark.shield.fill",
                            tint: .red,
                            title: Strings.Verification.refusedTitle,
                            message: Strings.Verification.refusedMessage)

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
                // No way out of the question but through it. While the user is being asked whether
                // a device is theirs, a close button is a third answer that means neither yes nor
                // no, and the device on the other end would be left waiting on it. The two answers
                // below are both ways out, and one of them takes half a second.
                if !isAsking {
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
        // And the swipe is not a third answer either. Same reason as the missing close button —
        // this is the one modal in the app the user must answer rather than dismiss, exactly like
        // the recovery key they must be made to look at.
        .interactiveDismissDisabled(isAsking)
    }

    private var isAsking: Bool { verification.step == .asked }

    /// A device of yours signing in, asking to be trusted — and the one thing the user is being
    /// asked to do is *recognise it*. So the device's name is the largest thing on the screen, and
    /// the ID is under it in a monospaced font, because names are chosen by whoever set the device
    /// up and two of them can read the same.
    ///
    /// "It's not mine" is not styled as the frightening answer and "It's mine" is not styled as the
    /// easy one. Both are bordered, both are the same size. If the app made agreeing the
    /// comfortable button, the app would be helping whoever is on the other end.
    @ViewBuilder
    private var asked: some View {
        if let request = verification.incoming {
            VStack(spacing: Theme.Spacing.generous) {
                Image(systemName: "laptopcomputer.and.iphone")
                    .font(.largeTitle)
                    .foregroundStyle(accent.color)

                VStack(spacing: Theme.Spacing.tight) {
                    Text(request.deviceName ?? String(app: Strings.Verification.unnamedDevice))
                        .font(.title2.weight(.semibold))
                        .multilineTextAlignment(.center)

                    Text(request.deviceID)
                        .font(.footnote.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                Text(Strings.Verification.askedMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Spacer()

                HStack(spacing: Theme.Spacing.normal) {
                    Button {
                        Task { await verification.refuse() }
                    } label: {
                        Text(Strings.Verification.notMine)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        Task { await verification.accept() }
                    } label: {
                        Text(Strings.Verification.mine)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(accent.color)
                }
                .controlSize(.large)
                .disabled(verification.isWorking)
            }
            .padding(Theme.Spacing.generous)
        }
    }

    /// The seconds between agreeing and the pictures. Short, and named rather than left as a bare
    /// spinner: an app that says nothing while it works is an app that looks stuck.
    private var negotiating: some View {
        ContentUnavailableView {
            Label(Strings.Verification.negotiatingTitle, systemImage: "ellipsis.circle")
        } description: {
            Text(Strings.Verification.negotiatingMessage)
        } actions: {
            ProgressView()
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
            // Centred, and on both rows when seven do not fit on one. They are the subject of the
            // screen and belong to nothing on either side of them — left-aligned, a short second row
            // hangs off the corner of the first and reads as a mistake rather than as a continuation.
            FlowLayout(spacing: Theme.Spacing.roomy, alignment: .center) {
                ForEach(Array(symbols.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol)
                        .font(.system(size: Theme.Size.verificationEmoji))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Theme.Spacing.generous)
            // One element to VoiceOver, reading the seven in order: a screen reader user compares
            // them by hearing them, and seven separate stops with no context is not a comparison.
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(symbols.joined(separator: ", ")))

            Spacer()

            // Neither answer is the prominent one — both are `.bordered`, and the note on the type
            // still holds: the app does not get to make the trust-granting answer the easy one.
            // Colour is not prominence here, it is meaning. Green agrees, red refuses, and they are
            // the two colours everyone already reads that way without being told.
            //
            // Equal heights, and it takes saying so: "They don't match" is the longer sentence and
            // wraps to two lines where "They match" does not, so left alone the two buttons came out
            // different sizes — and a difference in size between two answers is the screen putting a
            // thumb on the scale. `maxHeight: .infinity` on both labels makes each fill the row, and
            // the row is as tall as the taller of them.
            HStack(spacing: Theme.Spacing.normal) {
                Button {
                    Task { await verification.decline() }
                } label: {
                    Text(Strings.Verification.noMatch)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.red)

                Button {
                    Task { await verification.approve() }
                } label: {
                    Text(Strings.Verification.match)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.green)
            }
            // Pins the row to the height of its tallest button rather than letting the two unbounded
            // labels stretch it into whatever space the `Spacer` above has left lying around.
            .fixedSize(horizontal: false, vertical: true)
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
