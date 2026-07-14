import SwiftUI
import AVFoundation
import IskraCore
import IskraDesign

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The camera preview, masked to the circle the recording will actually be.
///
/// `.resizeAspectFill` matters: the preview must show the same centre crop that
/// `SquareVideoExporter` will take, or the user frames their face inside a circle and
/// gets something else back.
struct CameraPreview: PlatformViewRepresentable {
    let session: AVCaptureSession

    func makePlatformView() -> PreviewView {
        let view = PreviewView()
        view.layer(for: session)
        return view
    }

    func updatePlatformView(_ view: PreviewView) {}

    final class PreviewView: PlatformView {
        private var previewLayer: AVCaptureVideoPreviewLayer?

        func layer(for session: AVCaptureSession) {
            let preview = AVCaptureVideoPreviewLayer(session: session)
            preview.videoGravity = .resizeAspectFill

            #if os(macOS)
            wantsLayer = true
            layer = CALayer()
            layer?.addSublayer(preview)
            #else
            layer.addSublayer(preview)
            #endif

            previewLayer = preview
        }

        #if os(macOS)
        override func layout() {
            super.layout()
            previewLayer?.frame = bounds
        }
        #else
        override func layoutSubviews() {
            super.layoutSubviews()
            previewLayer?.frame = bounds
        }
        #endif
    }
}

/// Recording a round video message: the camera over the conversation, not instead of it.
///
/// Hold the button to record, let go to send — the same gesture as the thing this is
/// modelled on, and the one that makes a sixty-second cap feel like a feature rather
/// than a restriction.
///
/// An overlay and not a sheet. A sheet is a *place you go*: it slides up, it takes the screen,
/// and it puts the room behind a card. But a round video message is a remark in a conversation
/// that is still going on — you are answering the thing on the screen, and it should still be
/// on the screen, blurred back behind the camera rather than shoved out from under it. It also
/// makes the geometry honest: the shutter is exactly where the composer's button was, because
/// nothing moved.
struct VideoNoteComposer: View {
    /// The recorder, owned by the *screen* rather than by this sheet.
    ///
    /// It has to be. The hold that starts a recording begins on a button in the composer, and
    /// the finger is still down on that button while this sheet comes up — so the thing that
    /// stops the recording when the finger lifts is a gesture out there, and it has to be able
    /// to reach the same recorder that is in here. A `@State` recorder of this sheet's own would
    /// be a second one, born the moment the sheet appeared, with nobody holding it.
    let recorder: VideoNoteRecorder

    /// Whether the finger that opened this sheet is still down on the button that opened it.
    ///
    /// True when the sheet was raised by a *hold* on the composer's video button and the user
    /// has not let go. The screen owns it, because the gesture is out there — and this sheet
    /// reads it twice: to know whether to start recording the moment the camera wakes up, and to
    /// know whether to tell the user to let go.
    ///
    /// It goes false when they lift their finger, and if the camera has not come up by then,
    /// nothing is recorded. That is right: there is nothing worth sending in a hold that was
    /// over before the camera woke.
    @Binding var isHolding: Bool

    /// Set when the user has swiped up to record without holding. The sheet then keeps recording
    /// after the finger lifts, and the shutter becomes a stop button.
    @Binding var isLocked: Bool

    /// The swipe up that would let go of the recording — read from the composer's gesture, by way
    /// of the screen, and only drawn here.
    ///
    /// The pill the thumb is climbing towards has to be drawn twice: the composer draws one above
    /// its record button, and this overlay is *on top of the composer*, blurring it out. The
    /// finger is still down on a button it can no longer see. So the same pill is drawn again
    /// here, above the shutter — which stands in exactly the place the record button stands, on
    /// purpose (see `shutter`), so the thumb is climbing towards the same point on the glass
    /// either way and never learns that it changed hands.
    ///
    /// Handed over whole rather than worked out again from `isHolding` and `isLocked`. Those two
    /// move in the same instant when a swipe catches, and an overlay that watched them separately
    /// would blink the pill out on the very movement it is there to confirm.
    var lock: LockGesture = LockGesture()

    /// Thrown away. The screen owns the recorder, so it owns the throwing away too — and it has
    /// to take this overlay down with it, which is a thing only the screen can do.
    let onCancel: () -> Void

    let onRecorded: (URL) async -> Void

    @Environment(\.accent) private var accent

    // No defaults on the two bindings. `isLocked` used to default to `.constant(true)`, which is
    // a binding that cannot be written — so a composer built without one would set the lock, the
    // write would go nowhere, and the screen would never hear that the finger had been let go of.
    // Every one of these is a channel back to the screen, and a channel with a default is a
    // channel that can be silently left unplugged.
    init(recorder: VideoNoteRecorder,
         isHolding: Binding<Bool>,
         isLocked: Binding<Bool>,
         lock: LockGesture = LockGesture(),
         onCancel: @escaping () -> Void,
         onRecorded: @escaping (URL) async -> Void) {
        self.recorder = recorder
        _isHolding = isHolding
        _isLocked = isLocked
        self.lock = lock
        self.onCancel = onCancel
        self.onRecorded = onRecorded
    }

    var body: some View {
        ZStack {
            // The conversation, still there and out of focus. Darkened as well as blurred: a
            // blur alone leaves a bright room bright, and the camera has to be the lit thing on
            // the screen.
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(Color.black.opacity(Theme.Backdrop.dim))
                .ignoresSafeArea()

            VStack(spacing: Theme.Spacing.roomy) {
                Spacer(minLength: 0)

                circle

                trouble

                Spacer(minLength: 0)

                controls
            }
            // Narrow at the sides, because the circle is now measured against them: a roomy
            // margin here is width taken off the thing the user is framing their face in.
            .padding(.vertical, Theme.Spacing.roomy)
            .padding(.horizontal, Theme.Spacing.close)
        }
        .task {
            await recorder.prepare()

            // The finger came down on the composer's button, the camera came up, and it took as
            // long as a camera takes. Recording begins the moment it is ready — which is the
            // whole point of the hold: one movement, not two.
            if isHolding {
                startRecording()
            }
        }
        // The camera takes a moment to wake, so this tap is the only thing that says the clip is
        // running. Heavy, at full intensity — it has to be felt through a phone held at arm's
        // length, in a hand that is busy holding the thing steady.
        .sensoryFeedback(.impact(weight: .heavy, intensity: 1), trigger: started)
    }

    @ViewBuilder
    private var circle: some View {
        ZStack {
            if let session = recorder.session {
                CameraPreview(session: session)
            } else {
                Circle().fill(.quaternary)
            }
        }
        // Square by aspect rather than by a fixed width, so the circle grows to whatever the
        // screen gives it and `videoNoteCamera` is only the point at which it stops.
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: Theme.Size.videoNoteCamera)
        .clipShape(.circle)
        .overlay {
            // The ring fills as the sixty seconds run down, so the limit is visible
            // rather than a surprise.
            Circle()
                .trim(from: 0, to: recorder.progress)
                // White, not red. Red is the colour of a warning, and nothing here is going
                // wrong — the ring is just the minute running out. It also has to read against
                // whatever the camera happens to be pointing at, and white on a dimmed,
                // blurred backdrop reads where red on a red jumper does not.
                .stroke(.white, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.1), value: recorder.progress)
        }
        .accessibilityLabel(Text(Strings.VideoNote.title))
    }

    /// The two things that can be wrong, and the one thing worth saying while it works.
    ///
    /// No "hold to record" here any more: by the time this is on the screen the hold has already
    /// happened. What is left to say is how to get out of it hands-free, and only while there is
    /// still a hand on it.
    /// It is never *removed*, only faded out, and the line it leaves behind is left holding its
    /// own height. Taking it away instead is what made the whole overlay jump the moment a hold
    /// became a locked recording — the circle and the controls, which have nothing to do with what
    /// the line says, slid up the screen to fill a gap in the sentence underneath them. Locking a
    /// recording should look like nothing happening to the camera.
    private var trouble: some View {
        Text(hint ?? " ")
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            // Kept off the edges of the phone — "hold to send" is a short line, but "the camera
            // is not allowed" is two, and a sentence that runs into the bezel reads as broken.
            .frame(maxWidth: Theme.Size.videoNoteHint)
            .opacity(hint == nil ? 0 : 1)
            .animation(.smooth(duration: 0.2), value: hint == nil)
            .accessibilityHidden(hint == nil)
    }

    /// The two things that can be wrong, and the one thing worth saying while it works — or
    /// nothing, which is a state the line above still occupies.
    private var hint: LocalizedStringResource? {
        switch recorder.state {
        case .denied: Strings.VideoNote.needsCamera
        case .unavailable: Strings.VideoNote.noCamera
        case .finishing: Strings.VideoNote.sending
        case .recording where isHolding: Strings.VideoNote.releaseToSend
        default: nil
        }
    }

    /// The bar along the bottom: what is being recorded, the way out of it, and the way to send
    /// it — in that order, left to right, ending under the thumb.
    private var controls: some View {
        HStack(alignment: .bottom, spacing: Theme.Spacing.close) {
            VStack(alignment: .leading, spacing: Theme.Spacing.close) {
                flip
                RecordingStrip(elapsed: recorder.elapsed,
                               onCamera: true,
                               onCancel: onCancel)
            }

            // The pill sits directly over the shutter, which sits directly over the composer's
            // record button, which is where the finger is. Three things in one column, and the
            // user only ever sees the ones that are theirs to see — a recording begun from the
            // shutter is hands-free already, was never held, and is offered no way to let go of
            // something nobody is holding.
            // The pill is always *here*, and only sometimes visible. Taken out of the layout when
            // it is not — which is what an `if` does — it takes its height with it, the bar of
            // controls shrinks, and the whole overlay above them slides down: the camera jumped
            // at the exact moment the lock caught, which is the moment it must not. Fading and
            // shrinking it in place leaves the room it stands in untouched.
            //
            // Safe here in a way it would not be in the composer: this pill is an opaque fill on a
            // blurred backdrop, not glass, so nothing draws it whatever it says about its own
            // opacity. In `MessageComposer` it lives inside a `GlassEffectContainer`, which draws
            // its material regardless — see `RecordLock`'s note, and leave the `if` there alone.
            VStack(spacing: Theme.Spacing.close) {
                RecordLock(gesture: lock, onCamera: true)
                    .scaleEffect(lock.isVisible ? 1 : 0.4, anchor: .bottom)
                    .opacity(lock.isVisible ? 1 : 0)

                shutter
            }
        }
        .animation(.smooth(duration: 0.2), value: lock.isVisible)
    }

    /// Turns the camera round, mid-recording and all — which is the only time it is any use,
    /// because with hold-to-record the camera is *always* recording by the time it is on screen.
    /// See `VideoNoteRecorder.flip`, which used to refuse this and now does not.
    ///
    /// Present only where there is a second lens to turn to. On a Mac there is not, and a button
    /// that does nothing is worse than no button.
    @ViewBuilder
    private var flip: some View {
        if recorder.canFlip {
            Button {
                recorder.flip()
            } label: {
                Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90")
                    .font(.body)
                    .foregroundStyle(.white)
                    .frame(width: Theme.Size.minimumTapTarget, height: Theme.Size.minimumTapTarget)
                    .background(.black.opacity(0.45), in: .circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(Strings.VideoNote.flipCamera))
        }
    }

    /// Send. The big pale circle in the corner, which is where the finger already is — it is
    /// directly over the composer's record button, because the overlay did not move anything.
    ///
    /// It is a *send* button and not a stop button, even though stopping is what it makes the
    /// recorder do, because stopping is not why anybody presses it. Before the recording starts
    /// it is still the shutter: hold it, and the camera runs.
    private var shutter: some View {
        Circle()
            .fill(isRecording ? AnyShapeStyle(accent.color) : AnyShapeStyle(.quaternary))
            .frame(width: Theme.Size.recordingSend, height: Theme.Size.recordingSend)
            .overlay {
                Image(systemName: isRecording ? "arrow.up" : "video.fill")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(isRecording ? accent.foreground : AnyShapeStyle(.primary))
            }
            .animation(.smooth(duration: 0.2), value: isRecording)
            // Two gestures, and which one is live depends on whether anything is being recorded.
            //
            // It used to be one: a long press that started the clip, sequenced before a drag
            // that ended it. That reads well until the recording is already running — started
            // by the finger out on the composer, and still running hands-free — at which point
            // this circle is a send button wearing an arrow, and `sequenced` still insisted on
            // the hundred milliseconds of long press before it would look at the release. A tap
            // is often shorter than that. So the one button on the screen the thumb is looking
            // for silently did nothing to a decisive tap, and worked only if you pressed and
            // held it, which is not a thing a send button has ever asked of anybody.
            .gesture(hold, isEnabled: !isRecording)
            .gesture(TapGesture().onEnded { recorder.stop() }, isEnabled: isRecording)
            .disabled(!canRecord)
            .opacity(canRecord ? 1 : 0.4)
            .accessibilityLabel(Text(isRecording ? Strings.Recording.send : Strings.VideoNote.holdToRecord))
            .accessibilityAddTraits(.isButton)
            // Neither a long press nor a tap gesture is something VoiceOver performs — it
            // activates, and an activation reaches neither. Without this the shutter announces
            // itself as a button and then ignores the only way VoiceOver has of pressing one,
            // which left a VoiceOver user unable to record a video message at all.
            .accessibilityAction {
                if isRecording { recorder.stop() } else { beginFromShutter() }
            }
    }

    /// Hold the shutter and the camera runs; the clip is then hands-free and the same circle,
    /// now an arrow, sends it.
    ///
    /// Releasing does *not* send, which is the one way this differs from the composer's button.
    /// A recording started in here belongs to the shutter rather than to the finger out on the
    /// composer, and letting the two of them both try to end the same clip meant the second one
    /// landing on a recorder that had already sent it. So it is locked the moment it begins, and
    /// there is exactly one thing that ends it: a tap.
    private var hold: some Gesture {
        LongPressGesture(minimumDuration: 0.1)
            .onEnded { _ in beginFromShutter() }
    }

    private func beginFromShutter() {
        isLocked = true
        started += 1
        startRecording()
    }

    /// The camera rolling, felt rather than seen.
    ///
    /// Only for a recording begun *here*, on the shutter. One begun by a hold out on the composer
    /// has already been answered by the composer's own tap, and a second one landing half a second
    /// later — when the camera finally wakes — would read as a stutter rather than as an answer.
    /// The lock has no tap here either, for the same reason: the swipe that sets it is the
    /// composer's gesture, and the composer has already said so, in the same movement.
    @State private var started = 0

    private var isRecording: Bool { recorder.isRecording }

    private var canRecord: Bool {
        recorder.state == .ready || isRecording
    }

    private func startRecording() {
        recorder.start { url in
            await onRecorded(url)
        }
    }
}

// MARK: - One representable for two platforms

#if os(macOS)
public typealias PlatformView = NSView
#else
public typealias PlatformView = UIView
#endif

/// `NSViewRepresentable` and `UIViewRepresentable` are the same protocol wearing
/// different names. This is the seam that lets the camera preview be written once.
protocol PlatformViewRepresentable: PlatformViewRepresentableBase {
    associatedtype ViewType: PlatformView
    func makePlatformView() -> ViewType
    func updatePlatformView(_ view: ViewType)
}

#if os(macOS)
protocol PlatformViewRepresentableBase: NSViewRepresentable {}

extension PlatformViewRepresentable where NSViewType == ViewType {
    func makeNSView(context: Context) -> ViewType { makePlatformView() }
    func updateNSView(_ view: ViewType, context: Context) { updatePlatformView(view) }
}
#else
protocol PlatformViewRepresentableBase: UIViewRepresentable {}

extension PlatformViewRepresentable where UIViewType == ViewType {
    func makeUIView(context: Context) -> ViewType { makePlatformView() }
    func updateUIView(_ view: ViewType, context: Context) { updatePlatformView(view) }
}
#endif
