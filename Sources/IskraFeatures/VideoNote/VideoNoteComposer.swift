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
         onCancel: @escaping () -> Void,
         onRecorded: @escaping (URL) async -> Void) {
        self.recorder = recorder
        _isHolding = isHolding
        _isLocked = isLocked
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
            .padding(Theme.Spacing.roomy)
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
        .frame(width: Theme.Size.videoNoteCamera, height: Theme.Size.videoNoteCamera)
        .clipShape(.circle)
        .overlay {
            // The ring fills as the sixty seconds run down, so the limit is visible
            // rather than a surprise.
            Circle()
                .trim(from: 0, to: recorder.progress)
                .stroke(.red, style: StrokeStyle(lineWidth: 4, lineCap: .round))
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
    @ViewBuilder
    private var trouble: some View {
        Group {
            switch recorder.state {
            case .denied:
                Text(Strings.VideoNote.needsCamera)
            case .unavailable:
                Text(Strings.VideoNote.noCamera)
            case .finishing:
                Text(Strings.VideoNote.sending)
            case .recording where isHolding:
                Text(Strings.VideoNote.releaseToSend)
            default:
                EmptyView()
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }

    /// The bar along the bottom: what is being recorded, the way out of it, and the way to send
    /// it — in that order, left to right, ending under the thumb.
    private var controls: some View {
        HStack(alignment: .bottom, spacing: Theme.Spacing.close) {
            VStack(alignment: .leading, spacing: Theme.Spacing.close) {
                flip
                RecordingStrip(elapsed: recorder.elapsed,
                               isHolding: isHolding,
                               onCamera: true,
                               onCancel: onCancel)
            }

            shutter
        }
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
        startRecording()
    }

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
