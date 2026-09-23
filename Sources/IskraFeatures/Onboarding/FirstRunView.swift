import SwiftUI
import IskraCore
import IskraDesign

/// The three screens between a sign-in and the conversations: a hello, the colour, and the faces.
///
/// Nothing here touches the account. Every one of these is a preference with a perfectly good
/// default already in it, which is why each of the two questions carries a way straight past it —
/// somebody who signed in wants their chats, not a colour picker, and an onboarding that cannot be
/// left is an onboarding people learn to resent.
///
/// A step of its own held in `@State` rather than a `NavigationStack` of pushes, for the reason
/// spelled out in `CLAUDE.md`: a screen that reads `@Environment(\.dismiss)` and pushes another is
/// the shape that hangs the Mac's sidebar. There is nothing to dismiss here — each step says when
/// it is done and the next one replaces it.
struct FirstRunView: View {
    /// Only for the name in the greeting. The session is up by the time this is on screen — it was
    /// started on the way through `RecoverySetupView` — and nothing on these screens waits for it.
    let session: UserSession

    /// Into the conversations.
    let onDone: () -> Void

    @State private var step: Step = .greeting

    private enum Step { case greeting, appearance, faces }

    var body: some View {
        // A `ZStack`, so the step leaving and the step arriving are on screen together for as
        // long as it takes one to hand over to the other. A `Group` around a `switch` puts them
        // in the same place in the hierarchy and SwiftUI is at liberty to swap them in a single
        // frame; stacked, the one on its way out has somewhere to be while it goes.
        ZStack {
            switch step {
            case .greeting:
                GreetingStep(name: session.displayName,
                             avatarURL: session.avatarURL,
                             userID: session.userID) { advance(to: .appearance) }
            case .appearance:
                AppearanceStep { advance(to: .faces) }
            case .faces:
                FacesStep(onDone: onDone)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The face on the greeting is the account's own picture, and a picture is bytes off the
        // homeserver like any other — so this run of screens needs the loader the rest of the app
        // gets at the root. It is the only thing here that touches the network, and it is asked
        // for one image.
        .environment(\.mediaLoader, session.media())
    }

    /// One step on.
    ///
    /// The animation is on the *change* rather than on the view, which is the difference between
    /// a flow that moves and a flow that also lurches whenever something inside a step changes —
    /// `.animation(_:value:)` on the container would take the slider on the faces screen with it.
    private func advance(to next: Step) {
        withAnimation(Theme.Timing.stepChanges) { step = next }
    }
}

extension AnyTransition {
    /// How one first-run screen gives way to the next.
    ///
    /// Sideways, and always the same way: this is three screens in a fixed order with no way
    /// back, so the movement can say so. The screen leaving goes out to the left and the one
    /// arriving comes in from the right — the direction a page is turned — and both fade, because
    /// a slide without a fade at this size reads as the whole app sliding rather than as one
    /// screen replacing another.
    static var onboardingStep: AnyTransition {
        .asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity))
    }
}

/// "Hello, Boris" — the one screen in the app that asks for nothing.
///
/// It is on a clock and has no button, which is the whole of its character: it is the app saying
/// hello, not a step somebody has to acknowledge. Three seconds (`Theme.Timing.greeting`), and
/// the name is whatever the account calls itself at that moment — a fresh account often calls
/// itself nothing at all, and there is a greeting for that too rather than a stray comma.
private struct GreetingStep: View {
    let name: String

    /// The picture on the account, if the person arrived with one — the same `mxc://` the chat
    /// list draws them by. Very often nil, and that is the ordinary case rather than the sad one:
    /// what stands in for it is either their initial or the creature their ID comes out as,
    /// exactly as everywhere else in the app. See `Avatar`.
    let avatarURL: String?

    /// What a drawn face is computed from, which is the Matrix ID and never the name — a face
    /// that changed when somebody edited their profile would not be a face.
    let userID: String

    let onDone: () -> Void

    /// Whether the hello has landed.
    ///
    /// False for the first frame on purpose. A greeting that is simply *there* when the screen
    /// appears is a heading; this one is the app saying hello to somebody by name, and for that
    /// to be seen happening there has to be a frame it was not in yet. See `Theme.Timing.aFrame`.
    @State private var hasLanded = false

    var body: some View {
        VStack(spacing: Theme.Spacing.roomy) {
            // Their own face, over their own name. It is the first thing in the app that belongs
            // to *them* rather than to the app, which is the whole reason it is here: the sign-in
            // before this screen was a form, and this is the account it turned into.
            Avatar(name: name, url: avatarURL, size: Theme.Size.avatarProfile, seed: userID)
                .scaleEffect(hasLanded ? 1 : 0.8)
                .opacity(hasLanded ? 1 : 0)
                .animation(Theme.Timing.arrival, value: hasLanded)

            Text(greeting)
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)
                .opacity(hasLanded ? 1 : 0)
                .offset(y: hasLanded ? 0 : Theme.Spacing.normal)
                // A moment behind the face, so the two read as one thing arriving and not as two
                // things switched on. See `Theme.Timing.stagger`.
                .animation(Theme.Timing.arrival.delay(Theme.Timing.stagger), value: hasLanded)
        }
        .padding(Theme.Spacing.generous)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transition(.onboardingStep)
        .task {
            // Drawn where it starts, and only then asked to move — one frame, which nobody sees
            // and which is the difference between an animation and a screen that is simply
            // already finished.
            try? await Task.sleep(for: Theme.Timing.aFrame)
            guard !Task.isCancelled else { return }
            hasLanded = true

            try? await Task.sleep(for: Theme.Timing.greeting)
            // Not on the way out. A cancelled sleep means this screen is already gone, and
            // moving the flow on from a view that has left would skip the screen after it.
            guard !Task.isCancelled else { return }
            onDone()
        }
    }

    private var greeting: LocalizedStringResource {
        let called = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return called.isEmpty ? Strings.Onboarding.greetingNameless : Strings.Onboarding.greeting(called)
    }
}

/// The colour, asked once, on a screen of its own.
///
/// The same swatches as the appearance screen (`AccentSwatches`) over the same two lines of a
/// conversation that never happened — because the swatch says what the colour *is* and only the
/// bubble says what it will be like to live in. The choice is written straight to `@AppStorage`,
/// so the screen it is made on repaints under the finger that makes it and there is nothing to
/// apply.
private struct AppearanceStep: View {
    let onDone: () -> Void

    @AppStorage(AccentTheme.storageKey) private var accent: AccentTheme = .default

    /// How many of the two lines have been said. The preview is a conversation, and a
    /// conversation that is simply *there* is a screenshot of one — see `speak()`.
    @State private var spokenLines = 0

    /// Whether the reply is in the middle of its nudge, which is what it does when the colour
    /// under it changes — see `nod()`.
    @State private var isNodding = false

    var body: some View {
        OnboardingPage(title: Strings.Onboarding.appearanceTitle,
                       explanation: Strings.Onboarding.appearanceBody,
                       onContinue: onDone,
                       onSkip: onDone) {
            VStack(spacing: Theme.Spacing.generous) {
                conversation
                AccentSwatches(accent: $accent)
            }
        }
        .task { await speak() }
        // The colour changed under the reply, so the reply says it noticed. The swatch already
        // takes the tick and the ring; this is the other half of the answer, on the thing the
        // choice is actually about.
        .onChange(of: accent) { _, _ in nod() }
    }

    private var conversation: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.close) {
            line(Strings.Appearance.previewAsk, isOwn: false, position: 0)
            line(Strings.Appearance.previewAnswer, isOwn: true, position: 1)
        }
        // Read as one thing: VoiceOver has no business walking somebody through a fake
        // conversation on the way to the colours they are here for.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(Strings.Appearance.previewLabel))
    }

    /// One line of the preview, drawn whether or not it has been said yet.
    ///
    /// Always in the layout and merely invisible, rather than inserted when its turn comes. A
    /// bubble that appears out of nothing takes its height with it, so the swatches below would
    /// be pushed down twice on the way in — and the colours are what this screen is for. They do
    /// not move.
    private func line(_ text: LocalizedStringResource, isOwn: Bool, position: Int) -> some View {
        let hasLanded = spokenLines > position

        return Text(text)
            .font(.callout)
            .messageBubble(isOwn ? .own : .incoming)
            .frame(maxWidth: .infinity, alignment: isOwn ? .trailing : .leading)
            .opacity(hasLanded ? 1 : 0)
            .offset(y: hasLanded ? 0 : Theme.Spacing.normal)
            // Only the reply nods: it is the one bubble on this screen wearing the colour.
            .scaleEffect(isOwn && isNodding ? Theme.Scale.nod : 1)
            .animation(Theme.Timing.arrival, value: hasLanded)
    }

    /// The conversation, said rather than displayed.
    ///
    /// The first frame is the point of the sleep before it, exactly as in `GreetingStep`: a view
    /// asked to animate from a value that was never drawn is put straight at its final one, so
    /// the lines are drawn where they start and *then* asked to land.
    private func speak() async {
        try? await Task.sleep(for: Theme.Timing.aFrame)
        guard !Task.isCancelled else { return }
        spokenLines = 1

        try? await Task.sleep(for: Theme.Timing.previewReplies)
        guard !Task.isCancelled else { return }
        spokenLines = 2
    }

    /// The reply's nudge when a new colour lands on it.
    ///
    /// Two updates and a frame between them, and the frame is load-bearing: setting the scale and
    /// animating it back inside one function would leave SwiftUI with a state that never changed,
    /// and nothing would happen at all. So it is put up on one pass and let go on the next.
    private func nod() {
        isNodding = true
        Task { @MainActor in
            try? await Task.sleep(for: Theme.Timing.aFrame)
            withAnimation(Theme.Timing.arrival) { isNodding = false }
        }
    }
}

/// Who gets a drawn creature, asked as one slider with three stops — see `FaceMode`.
///
/// Two faces stand under it, and they are the point of the screen rather than decoration: the
/// three positions differ only in how they treat *two kinds of people*, somebody who set a picture
/// and somebody who never did, so a preview with one face in it could not show the difference
/// between the second position and the third.
private struct FacesStep: View {
    let onDone: () -> Void

    var body: some View {
        OnboardingPage(title: Strings.Onboarding.facesTitle,
                       explanation: Strings.Onboarding.facesBody,
                       onContinue: onDone,
                       onSkip: onDone) {
            FaceModePicker()
        }
    }
}

/// The question itself — two sample people, the slider and what the chosen stop means — without
/// the page around it, so that the same picker is asked again under Appearance, word for word.
struct FaceModePicker: View {

    // The App Group's defaults, not the app's own — the notification extension reads these two,
    // and a switch only the app can see is a switch the lock screen disobeys. See `BetaFeatures`.
    @AppStorage(BetaFeatures.blobatarKey, store: BetaFeatures.faceStore)
    private var drawsCreatures = BetaFeatures.blobatarByDefault
    @AppStorage(BetaFeatures.forceBlobatarKey, store: BetaFeatures.faceStore)
    private var overridesPictures = BetaFeatures.forceBlobatarByDefault

    private var mode: FaceMode {
        FaceMode(drawsCreatures: drawsCreatures, overridesPictures: overridesPictures)
    }

    /// The slider's view of the same pair of switches. Rounded on the way in, because a slider
    /// with a step still hands over a `Double` and `Int(2.9999)` is 2 only by luck.
    private var position: Binding<Double> {
        Binding(get: { Double(mode.rawValue) },
                set: { value in
                    let chosen = FaceMode(rawValue: Int(value.rounded())) ?? .pictures
                    withAnimation(.smooth(duration: Theme.Timing.reaction)) {
                        drawsCreatures = chosen.drawsCreatures
                        overridesPictures = chosen.overridesPictures
                    }
                })
    }

    var body: some View {
    VStack(spacing: Theme.Spacing.generous) {
        faces

        VStack(spacing: Theme.Spacing.close) {
            Slider(value: position, in: 0...Double(FaceMode.allCases.count - 1), step: 1)
                .accentControl()
                .accessibilityLabel(Text(Strings.Onboarding.facesTitle))
                .accessibilityValue(Text(Strings.Onboarding.faceMode(mode)))

            // The three stops, named under the track they belong to. The chosen one is
            // the only one in full strength, because a slider handle between three
            // equally black words does not say which one it has landed on.
            HStack(alignment: .top) {
                ForEach(FaceMode.allCases) { candidate in
                    Text(Strings.Onboarding.faceMode(candidate))
                        .font(.caption)
                        .multilineTextAlignment(alignment(of: candidate))
                        .foregroundStyle(candidate == mode ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                        .frame(maxWidth: .infinity, alignment: edge(of: candidate))
                }
            }
            .accessibilityHidden(true)
        }

        Text(Strings.Onboarding.faceModeHelp(mode))
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            // The sentence changes with the slider, and a sentence that is replaced in
            // place reads as the same sentence being corrected.
            .id(mode)
            .transition(.opacity)
    }
    }

    private func alignment(of candidate: FaceMode) -> TextAlignment {
        switch candidate {
        case .pictures: .leading
        case .mixed: .center
        case .faces: .trailing
        }
    }

    private func edge(of candidate: FaceMode) -> Alignment {
        switch candidate {
        case .pictures: .leading
        case .mixed: .center
        case .faces: .trailing
        }
    }

    private var faces: some View {
        HStack(spacing: Theme.Spacing.generous) {
            face(name: Strings.Onboarding.picturedName,
                 caption: Strings.Onboarding.withPicture,
                 seed: "@chloe:iskra.chat",
                 hasPicture: true)

            face(name: Strings.Onboarding.unpicturedName,
                 caption: Strings.Onboarding.withoutPicture,
                 seed: "@tim:iskra.chat",
                 hasPicture: false)
        }
    }

    private func face(name: LocalizedStringResource,
                      caption: LocalizedStringResource,
                      seed: String,
                      hasPicture: Bool) -> some View {
        VStack(spacing: Theme.Spacing.close) {
            ZStack {
                if mode.drawsCreatures && (!hasPicture || mode.overridesPictures) {
                    BlobatarView(seed: seed)
                } else if hasPicture {
                    photograph
                } else {
                    Circle()
                        .fill(.quaternary)
                        .overlay {
                            Text(String(app: name).prefix(1).uppercased())
                                .font(.system(size: Theme.Size.avatarProfile * 0.4, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                }
            }
            .frame(width: Theme.Size.avatarProfile, height: Theme.Size.avatarProfile)

            Text(name)
                .font(.callout.weight(.medium))

            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    /// A picture somebody set, drawn rather than fetched.
    ///
    /// There is no real photograph to show: these two people do not exist, and going to the
    /// network for a stranger's face to illustrate a settings screen is precisely the thing this
    /// feature exists to avoid. What matters is that it reads as *a picture* rather than as
    /// initials — so it is a filled circle with a figure in it, which is what a portrait looks
    /// like at ninety-six points.
    private var photograph: some View {
        Circle()
            .fill(LinearGradient(colors: [.orange, .pink],
                                 startPoint: .topLeading,
                                 endPoint: .bottomTrailing))
            .overlay {
                Image(systemName: "person.fill")
                    .font(.system(size: Theme.Size.avatarProfile * 0.5))
                    .foregroundStyle(.white)
                    .offset(y: Theme.Spacing.tight)
            }
    }
}

/// The shape both questions are asked in: a title, a sentence, the thing being chosen, and two
/// ways on — the button that says "yes, this one" and the sentence that says "not now".
///
/// One layout rather than two, so the second screen cannot drift a step away from the first: on a
/// run of screens somebody sees back to back, a title that moves by eight points between them is
/// read as the app stuttering.
private struct OnboardingPage<Content: View>: View {
    let title: LocalizedStringResource
    /// The sentence under the title. Not called `body`: a `View` already has one of those, and
    /// the compiler's complaint about it is nothing like the mistake.
    let explanation: LocalizedStringResource
    let onContinue: () -> Void
    let onSkip: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.generous) {
                VStack(spacing: Theme.Spacing.normal) {
                    Text(title)
                        .font(.largeTitle.bold())

                    Text(explanation)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .multilineTextAlignment(.center)

                content
            }
            .padding(Theme.Spacing.generous)
            .frame(maxWidth: Theme.Size.signInColumn)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        // The two ways on live at the foot of the *screen*, not at the foot of the content.
        //
        // As a last row inside the scroll view they sat wherever the question above them
        // happened to end — halfway up on the colour screen, off the bottom edge on the faces
        // one at the larger text sizes — so the button somebody is looking for moved between two
        // screens they see back to back. An inset takes them out of the scrolling altogether:
        // they are always in the same place, and the content scrolls underneath them.
        .safeAreaInset(edge: .bottom) { actions }
        .transition(.onboardingStep)
    }

    private var actions: some View {
        VStack(spacing: Theme.Spacing.normal) {
            Button(action: onContinue) {
                // `maxWidth` on the *label*, which is the only thing that widens a button here:
                // the style draws its capsule around whatever the label turns out to be, so a
                // frame put on the button itself widens the frame and leaves the pill hugging
                // the word inside it. See `busyLabel` in `SignInView`, which is this same trick.
                Text(Strings.Onboarding.continue)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassAction)
            .controlSize(.large)

            Button(action: onSkip) {
                Text(Strings.Onboarding.skip)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    // The full width, and a shape to go with it: a way out written in footnote
                    // is a small target, and the row it is on is empty either side of it.
                    .frame(maxWidth: .infinity, minHeight: Theme.Size.minimumTapTarget)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Theme.Spacing.generous)
        .padding(.bottom, Theme.Spacing.normal)
        .frame(maxWidth: Theme.Size.signInColumn)
        .frame(maxWidth: .infinity)
    }
}
