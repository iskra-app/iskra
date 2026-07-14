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
/// Cancel is always there, always says "cancel", and always looks the same — one word, whether the
/// finger is still down on the record button or the recording has been let go of and is running
/// hands-free. It used to grow an arrow mid-hold, pointing back along the swipe that also cancels;
/// it no longer does. The swipe is signposted at the record button, under the thumb, where the
/// thumb can see it — see `RecordLock` for the other half of that gesture. A strip with a live
/// recording in it does not also need to be a diagram.
struct RecordingStrip: View {
    let elapsed: TimeInterval

    /// What the microphone is hearing, when there is a microphone whose hearing is worth
    /// drawing. Empty under the camera: a waveform beside a live picture of somebody's face is
    /// a second thing to look at, and the face already says the recording is working.
    var waveform: [Float] = []

    /// Whether the strip is being drawn over the camera rather than in the composer, which
    /// decides what it is made of.
    ///
    /// Not decoration — it is the Liquid Glass rule (see `CLAUDE.md`). In the composer the strip
    /// *is* the navigation layer, floating over the conversation, and it is glass. Over the
    /// camera it is sitting on a full-screen blur, and glass on glass is the one thing the
    /// guideline flatly forbids: the material has nothing left to refract but more material. So
    /// there it is an opaque dark fill, the same one the flip button wears, on the same backdrop.
    var onCamera: Bool = false

    /// Whether the microphone is still listening.
    ///
    /// It is not always, and the strip stays up when it stops: iOS ends a recording without asking
    /// at the five-minute cap, when a call comes in, and when the app is put away, and what was said
    /// up to that point is still there and still worth sending. So the strip has to be able to say
    /// "this recording has ended and is waiting for you" as well as "I am listening" — and the
    /// difference is entirely in the dot, because the clock stops on its own. A dot that goes on
    /// breathing over a microphone that has been switched off is the screen telling a small lie to
    /// somebody who is still talking into it.
    var isLive: Bool = true

    let onCancel: () -> Void

    /// The strip sits in the row of composer buttons and must be exactly as tall as they are — so
    /// it scales with the reader's text exactly as they do. See `ScaledSize`.
    @ScaledSize(Theme.Size.composerControl) private var control

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
                // Grey once the microphone has stopped. Red is the colour of the thing that is
                // happening, and when it has stopped happening the dot is a full stop and not a
                // light. See `isLive`.
                .fill(isLive ? Color.red : Color.secondary)
                .frame(width: Theme.Size.recordingDot, height: Theme.Size.recordingDot)
                // A pulse, because a red dot that does not move is a design element and a red
                // dot that breathes is a thing that is happening. And when it is no longer
                // happening the dot stops breathing, which is the same sentence read backwards.
                .opacity(isPulsing && isLive ? 0.3 : 1)
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

            // The waveform takes what is left over, and never a point more. This has been got
            // wrong twice, both times the same way: the bars were an `HStack` of forty capsules
            // of a fixed width, and a frame around a fixed-width child only caps its *maximum* —
            // the minimum it still inherits, so the thing reported a hundred and sixty points as
            // the least it could live with and shouldered Cancel off the end of the strip. A
            // `maxWidth: .infinity` does not fix that, and neither does clipping, which changes
            // only what is drawn and not what is asked for.
            //
            // So the bars have no width of their own to insist on: `LiveWaveform` is a `Canvas`,
            // which has no ideal size and takes whatever it is proposed, down to nothing. The
            // strip cannot be broken by it now, whatever else changes above.
            if !waveform.isEmpty {
                LiveWaveform(samples: waveform)
                    .frame(minWidth: 0, maxWidth: .infinity)
                    .layoutPriority(-1)
            } else {
                Spacer(minLength: 0)
            }

            // Cancel is a button either way, and is *always* a button. It was a plain red label
            // while the finger was down, on the reasoning that a button under a finger that cannot
            // let go is a button nobody can press. Which is true of the finger that is holding the
            // record button, and false of the other nine.
            //
            // Pressing it mid-hold is safe, and that is worth saying because it looks as though
            // it should not be: releasing the record button afterwards runs `onFinishVoice`, and
            // `VoiceRecorder.finish()` on a recording that has been thrown away hands back
            // nothing. Nothing is what gets sent.
            //
            // One word, and the same word throughout — the arrow that used to grow out of it
            // mid-hold is gone. It was there to say "the swipe left ends at this word", and it
            // said it by putting a second, silent instruction into a strip that already has a
            // clock, a waveform and a live recording in it. The swipe is worth signposting where
            // the thumb *is*, which is the record button, and not at the far end of the bar where
            // nothing is happening.
            Button(action: onCancel) {
                Text(Strings.Recording.cancel)
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
        .frame(height: control)
        .frame(maxWidth: .infinity)
    }
}

/// The microphone's own picture of what it is hearing, drawn as it hears it.
///
/// The *last* samples, not the first: a voice message is being spoken now, and the shape that
/// matters is the shape of the words currently going in. Scrolling it is what makes the strip
/// look like a live meter rather than a chart that filled up and stopped.
///
/// It is a `Canvas` rather than a stack of `Capsule`s, and that is a layout decision before it is
/// a drawing one — see the caller. A view built out of fixed-width children has a minimum width
/// it will not go below, and in a row with a clock and a Cancel button that minimum is a battering
/// ram. A `Canvas` has none: it accepts whatever width it is proposed, and *then* decides how many
/// bars fit in it. Narrow strip, fewer bars; no strip at all, nothing drawn and nothing broken.
struct LiveWaveform: View {
    let samples: [Float]

    private static let barWidth: CGFloat = 2
    private static let spacing: CGFloat = 2

    var body: some View {
        Canvas { context, size in
            let step = Self.barWidth + Self.spacing
            let fitting = max(0, Int(size.width / step))
            guard fitting > 0 else { return }

            let visible = samples.suffix(fitting)
            let colour = GraphicsContext.Shading.style(.secondary)

            // Drawn right to left, from the trailing edge: the newest sound is the one being made,
            // and it stays put while the older bars run off the left of whatever room there is.
            for (index, sample) in visible.reversed().enumerated() {
                let height = max(Self.barWidth, CGFloat(sample) * size.height)
                let x = size.width - CGFloat(index + 1) * step
                let bar = CGRect(x: x,
                                 y: (size.height - height) / 2,
                                 width: Self.barWidth,
                                 height: height)

                context.fill(Path(roundedRect: bar, cornerRadius: Self.barWidth / 2), with: colour)
            }
        }
        .frame(height: Theme.Size.waveform)
    }
}
