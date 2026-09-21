import SwiftUI
import IskraDesign

/// The six slides that say what this app is, before anybody is asked to sign into it.
///
/// They move on their own and they can be swiped, and those two have to live together: a carousel
/// that only advances by itself takes the screen away from somebody mid-sentence, and one that
/// only advances by hand is six slides most people never see past the first. So the clock is
/// restarted by every swipe — the `.task(id:)` below is keyed on the slide, so touching it is the
/// same as the slide changing — and it **stops at the last one**. Once everything has been said
/// there is nothing to move to, and a pitch that loops back to the beginning reads as an app that
/// has not noticed you are still here.
///
/// There is one button and it is the way in. No "skip": the slides are not a step somebody has to
/// get past, they are the only thing on screen, and the button under them is on every one of them.
struct WelcomeView: View {
    /// Pressed "Get started" — the sign-in takes it from here.
    let onStart: () -> Void

    private let slides = Strings.Onboarding.Slide.allCases

    @State private var index = 0

    /// Which way the last change went, so the new slide comes in from the side it was going to.
    /// A carousel whose slides always arrive from the right contradicts a finger that just pushed
    /// one to the left.
    @State private var isMovingForward = true

    var body: some View {
        VStack(spacing: Theme.Spacing.generous) {
            Spacer(minLength: 0)

            slide

            Spacer(minLength: 0)

            dots

            Button(action: onStart) {
                // The width is put on the *label*, which is the only thing that widens a button
                // here: the style draws its capsule around whatever the label turns out to be, so
                // a frame on the button widens the frame and leaves the pill hugging the word
                // inside it. See `busyLabel` in `SignInView`, which is this same trick.
                Text(Strings.Onboarding.start)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassAction)
            .controlSize(.large)
        }
        .padding(Theme.Spacing.generous)
        .frame(maxWidth: Theme.Size.signInColumn)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The whole screen takes the swipe, not just the card: on a slide whose words are two
        // lines long the card is a small target in the middle of a lot of nothing, and a swipe
        // that lands on the nothing has to work or the carousel reads as broken.
        .contentShape(.rect)
        .gesture(swipe)
        .animation(.smooth, value: index)
        // Restarted by every change, including the ones a finger makes — see the note above.
        .task(id: index) {
            guard index < slides.count - 1 else { return }
            try? await Task.sleep(for: Theme.Timing.welcomeSlide)
            guard !Task.isCancelled else { return }
            move(by: 1)
        }
    }

    private var slide: some View {
        VStack(spacing: Theme.Spacing.generous) {
            mark

            VStack(spacing: Theme.Spacing.normal) {
                Text(slides[index].title)
                    .font(.largeTitle.bold())

                Text(slides[index].body)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .id(index)
        .transition(.push(from: isMovingForward ? .trailing : .leading).combined(with: .opacity))
    }

    /// The picture over each slide — **a placeholder**, and only that.
    ///
    /// The illustrations these slides are getting are not drawn yet, and a slide with nothing over
    /// its title is a slide whose layout changes the day they arrive. So the space is held at the
    /// size the picture will be (`Theme.Size.welcomeMark`), with a symbol standing in it, and the
    /// symbol says which slide it is on so that six placeholders do not read as one picture that
    /// failed to move.
    private var mark: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.picture, style: .continuous)
            .fill(.quaternary)
            .frame(width: Theme.Size.welcomeMark, height: Theme.Size.welcomeMark)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: Theme.Size.signInMark))
                    .foregroundStyle(.secondary)
            }
            .accessibilityHidden(true)
    }

    private var symbol: String {
        switch slides[index] {
        case .iskra: "bubble.left.and.bubble.right.fill"
        case .encryption: "lock.fill"
        case .decentralised: "point.3.connected.trianglepath.dotted"
        case .appleWay: "bolt.fill"
        case .freedom: "arrow.triangle.branch"
        case .anonymous: "person.fill.questionmark"
        }
    }

    /// Where you are in the six. Indicators, not controls — nobody aims at a dot this size, and
    /// the way between slides is the swipe beside it.
    private var dots: some View {
        HStack(spacing: Theme.Spacing.close) {
            ForEach(slides.indices, id: \.self) { position in
                Circle()
                    .fill(position == index ? AnyShapeStyle(.primary) : AnyShapeStyle(.quaternary))
                    .frame(width: Theme.Size.pageDot, height: Theme.Size.pageDot)
            }
        }
        // One element that says where the carousel is, and answers a swipe up or down by moving
        // it — which is how VoiceOver gets between slides, since the drag gesture below is not
        // something it can perform.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(Strings.Onboarding.slidePosition(index + 1, of: slides.count)))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: move(by: 1)
            case .decrement: move(by: -1)
            @unknown default: break
            }
        }
    }

    private var swipe: some Gesture {
        DragGesture(minimumDistance: Theme.Spacing.roomy)
            .onEnded { drag in
                guard abs(drag.translation.width) > Theme.Size.gestureReach else { return }
                move(by: drag.translation.width < 0 ? 1 : -1)
            }
    }

    /// One slide along, and nowhere past either end. The carousel does not wrap — see the note at
    /// the top — so a swipe at the last slide is a swipe that does nothing, which is the truthful
    /// answer to "is there more".
    private func move(by step: Int) {
        let destination = index + step
        guard slides.indices.contains(destination) else { return }
        isMovingForward = step > 0
        index = destination
    }
}
