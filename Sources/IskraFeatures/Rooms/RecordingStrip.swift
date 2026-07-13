import SwiftUI
import IskraDesign

/// What is being recorded, and the way to throw it away: a red dot, a clock, and "cancel".
///
/// Shared by both kinds of recording — the same strip appears in the composer while somebody is
/// speaking and under the camera while they are filming, because they are the same act and it
/// would be strange to give them two different-looking ways to abandon it. It lives in a file of
/// its own for exactly that reason: it belongs to neither caller, and it was briefly kept in one
/// of them, which meant the other had to reach into that file's scope to draw a waveform.
///
/// Cancel is always there and always says "cancel". What changes is how you work it, and that is
/// a consequence of the gesture rather than a choice of style.
///
/// A held recording is sent by letting go. So a Cancel *button* drawn under a finger that is still
/// down is a trap: reaching for it means releasing the record button, and releasing it is what
/// sends the message the user was trying to throw away. While the finger is down, Cancel is
/// therefore the target of the swipe — the word, in red, behind the arrow pointing the way to it
/// — and it becomes a plain button the moment the recording is running hands-free and there is a
/// hand free to press it. Which is also when it is most needed: a minute later, when the swipe is
/// long forgotten and somebody changes their mind.
struct RecordingStrip: View {
    let elapsed: TimeInterval

    /// What the microphone is hearing, when there is a microphone whose hearing is worth
    /// drawing. Empty under the camera: a waveform beside a live picture of somebody's face is
    /// a second thing to look at, and the face already says the recording is working.
    var waveform: [Float] = []

    /// Whether a finger is still down on the record button. It decides which way out this offers
    /// — see above: the button is unpressable, and worse than unpressable, until the finger lifts.
    var isHolding: Bool = false

    /// Whether the strip is being drawn over the camera rather than in the composer, which
    /// decides what it is made of.
    ///
    /// Not decoration — it is the Liquid Glass rule (see `CLAUDE.md`). In the composer the strip
    /// *is* the navigation layer, floating over the conversation, and it is glass. Over the
    /// camera it is sitting on a full-screen blur, and glass on glass is the one thing the
    /// guideline flatly forbids: the material has nothing left to refract but more material. So
    /// there it is an opaque dark fill, the same one the flip button wears, on the same backdrop.
    var onCamera: Bool = false

    let onCancel: () -> Void

    @State private var isPulsing = false

    /// Glass under the strip in the composer, an opaque dark fill under the camera — and in both
    /// cases the surface is applied *to* the strip rather than laid behind it as a `.background`.
    ///
    /// That distinction is not a style: the strip lives inside the composer's
    /// `GlassEffectContainer`, and a container gathers every piece of glass in it into one
    /// surface that it draws in one go. Glass reached through a `.background` is glass all the
    /// same, so the container collected it — and drew it in its own pass, over the clock and the
    /// waveform it was supposed to be sitting behind. The recording looked like it was under
    /// frosted plastic. Every other glass surface in the composer is applied straight to its
    /// content; this one now is too.
    var body: some View {
        if onCamera {
            strip.background(
                RoundedRectangle(cornerRadius: Theme.Radius.bubble, style: .continuous)
                    .fill(.black.opacity(Theme.Backdrop.dim))
            )
        } else {
            strip.navigationGlass(in: .rect(cornerRadius: Theme.Radius.bubble, style: .continuous))
        }
    }

    private var strip: some View {
        HStack(spacing: Theme.Spacing.close) {
            Circle()
                .fill(.red)
                .frame(width: Theme.Size.recordingDot, height: Theme.Size.recordingDot)
                // A pulse, because a red dot that does not move is a design element and a red
                // dot that breathes is a thing that is happening.
                .opacity(isPulsing ? 0.3 : 1)
                .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: isPulsing)
                .onAppear { isPulsing = true }
                .onDisappear { isPulsing = false }

            // The clock gives way to nothing. Everything in this strip except the waveform is a
            // fixed thing of a known size — and saying so is what keeps them where they are: an
            // `HStack` shares out what is left after the *flexible* children have been served,
            // and a `Text` at the default priority is one of them. Squeezed, it shifted about
            // and truncated, which on a clock reads as the recording having gone wrong.
            Text(Duration.seconds(elapsed), format: .time(pattern: .minuteSecond))
                .font(.callout.monospacedDigit())
                .fixedSize()
                .layoutPriority(1)

            // The waveform takes what is left over, and never a point more — which is what it
            // used to do. Forty bars four points apart is a hundred and sixty points of *fixed*
            // width, and a fixed-width thing in an `HStack` does not give way: on a phone it
            // simply shouldered Cancel off the end of the strip, where it could not be read and
            // could not be pressed. So it is drawn inside a frame that is happy with whatever
            // space it is given, clipped to it, and told to be the last in the queue for that
            // space. Clipped from the *left*, because the newest sound is on the right and the
            // newest sound is the one being made.
            if !waveform.isEmpty {
                LiveWaveform(samples: waveform)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .clipped()
                    .layoutPriority(-1)
            } else {
                Spacer(minLength: 0)
            }

            // Cancel is a button either way, and is *always* a button — that is the change. It
            // was a plain red label while the finger was down, on the reasoning that a button
            // under a finger that cannot let go is a button nobody can press. Which is true of
            // the finger that is holding the record button, and false of the other nine.
            //
            // Pressing it mid-hold is safe, and that is worth saying because it looks as though
            // it should not be: releasing the record button afterwards runs `onFinishVoice`, and
            // `VoiceRecorder.finish()` on a recording that has been thrown away hands back
            // nothing. Nothing is what gets sent.
            //
            // What changes with the finger is only what it *says*: while the recording is being
            // held, the arrow says the swipe will reach it, because that is the way out most
            // thumbs will take.
            Button(action: onCancel) {
                HStack(spacing: Theme.Spacing.tight) {
                    if isHolding {
                        Image(systemName: "chevron.left")
                    }

                    Text(Strings.Recording.cancel)
                }
                .font(.callout.weight(.medium))
                .foregroundStyle(.red)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, Theme.Spacing.close)
                .frame(minHeight: Theme.Size.minimumTapTarget)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .layoutPriority(1)
        }
        .foregroundStyle(onCamera ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .padding(.horizontal, Theme.Spacing.roomy)
        .frame(height: Theme.Size.composerControl)
        .frame(maxWidth: .infinity)
    }
}

/// The microphone's own picture of what it is hearing, drawn as it hears it.
///
/// The *last* forty samples, not the first: a voice message is being spoken now, and the shape
/// that matters is the shape of the words currently going in. Scrolling it is what makes the
/// strip look like a live meter rather than a chart that filled up and stopped.
struct LiveWaveform: View {
    let samples: [Float]

    private static let visible = 40

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(samples.suffix(Self.visible).enumerated()), id: \.offset) { _, sample in
                Capsule()
                    .fill(.secondary)
                    .frame(width: 2, height: max(2, CGFloat(sample) * Theme.Size.waveform))
            }
        }
        .frame(height: Theme.Size.waveform, alignment: .center)
        .animation(.linear(duration: 0.05), value: samples.count)
    }
}
