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
    let onRecorded: (URL) async -> Void

    @State private var recorder = VideoNoteRecorder()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accent) private var accent

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
                    Text(Duration.seconds(recorder.elapsed), format: .time(pattern: .minuteSecond))
                        .monospacedDigit()
                        .foregroundStyle(.red)
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
        .task { await recorder.prepare() }
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
                    .onEnded { _ in startRecording() }
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
