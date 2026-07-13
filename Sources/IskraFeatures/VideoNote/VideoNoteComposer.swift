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

/// Recording a round video message.
///
/// Hold the button to record, let go to send — the same gesture as the thing this is
/// modelled on, and the one that makes a sixty-second cap feel like a feature rather
/// than a restriction.
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

    let onRecorded: (URL) async -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accent) private var accent

    init(recorder: VideoNoteRecorder,
         isHolding: Binding<Bool> = .constant(false),
         isLocked: Binding<Bool> = .constant(true),
         onRecorded: @escaping (URL) async -> Void) {
        self.recorder = recorder
        _isHolding = isHolding
        _isLocked = isLocked
        self.onRecorded = onRecorded
    }

    var body: some View {
        VStack(spacing: Theme.Spacing.generous) {
            Text(Strings.VideoNote.title)
                .font(.headline)

            circle

            Group {
                switch recorder.state {
                case .denied:
                    Text(Strings.VideoNote.needsCamera)
                case .unavailable:
                    Text(Strings.VideoNote.noCamera)
                case .recording:
                    VStack(spacing: Theme.Spacing.tight) {
                        Text(Duration.seconds(recorder.elapsed), format: .time(pattern: .minuteSecond))
                            .monospacedDigit()
                            .foregroundStyle(.red)

                        // Only while the finger is still down on the composer's button. Once
                        // the recording is hands-free there is nothing to let go of, and
                        // telling somebody to release a button they are not holding is the app
                        // talking to itself.
                        if isHolding {
                            Text(Strings.VideoNote.releaseToSend)
                        }
                    }
                case .finishing:
                    Text(Strings.VideoNote.sending)
                default:
                    Text(Strings.VideoNote.holdToRecord)
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)

            shutter
        }
        .padding(Theme.Spacing.generous)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            await recorder.prepare()

            // The finger came down on the composer's button, the sheet came up, and the camera
            // took as long as a camera takes. Recording begins the moment it is ready — which is
            // the whole point of the hold: one movement, not two.
            if isHolding {
                startRecording()
            }
        }
        .onDisappear { recorder.cancel() }
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
        .frame(width: 260, height: 260)
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
        .overlay(alignment: .bottomTrailing) { flip }
        .accessibilityLabel(Text(Strings.VideoNote.title))
    }

    /// Turns the camera round, and sits on the circle it turns.
    ///
    /// On the edge of the preview rather than beside the shutter, because it acts on the
    /// picture and not on the recording — and because the thumb is already down there. It goes
    /// away entirely while recording (the lens cannot be swapped mid-clip; see
    /// `VideoNoteRecorder.flip`) and on a machine with only one camera.
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
            // While the ring is filling there is nothing to turn, so it leaves rather than
            // sitting there greyed out — a disabled button on a live preview reads as
            // something the app has broken.
            .opacity(isRecording ? 0 : 1)
            .animation(.smooth(duration: 0.2), value: isRecording)
            .disabled(isRecording)
            .accessibilityLabel(Text(Strings.VideoNote.flipCamera))
        }
    }

    /// Red while it is recording, and the accent before it starts — the same colour the
    /// send button wears, because this button sends too. Not `Color.accentColor`: that one
    /// is fixed at build time and would stay blue in a green app. See `AccentTheme`.
    private var shutter: some View {
        Circle()
            .fill(isRecording ? AnyShapeStyle(Color.red) : AnyShapeStyle(accent.color))
            .frame(width: 72, height: 72)
            .overlay {
                Image(systemName: isRecording ? "stop.fill" : "video.fill")
                    .font(.title2)
                    .foregroundStyle(isRecording ? AnyShapeStyle(.white) : accent.foreground)
            }
            .scaleEffect(isRecording ? 1.15 : 1)
            .animation(.smooth(duration: 0.2), value: isRecording)
            .gesture(
                LongPressGesture(minimumDuration: 0.1)
                    .onEnded { _ in
                        // A recording started *in here* belongs to this shutter, not to the
                        // finger out on the composer — so it is locked. Otherwise letting go of
                        // the shutter and letting go of the composer's button would both try to
                        // end the same clip, and the second one would land on a recorder that
                        // had already sent it.
                        isLocked = true
                        startRecording()
                    }
                    .sequenced(before: DragGesture(minimumDistance: 0).onEnded { _ in recorder.stop() })
            )
            .disabled(!canRecord)
            .opacity(canRecord ? 1 : 0.4)
            .accessibilityLabel(Text(Strings.VideoNote.holdToRecord))
            .accessibilityAddTraits(.isButton)
    }

    private var isRecording: Bool {
        if case .recording = recorder.state { return true }
        return false
    }

    private var canRecord: Bool {
        recorder.state == .ready || isRecording
    }

    private func startRecording() {
        recorder.start { url in
            await onRecorded(url)
            dismiss()
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
