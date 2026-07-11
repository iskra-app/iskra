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
        .accessibilityLabel(Text(Strings.VideoNote.title))
    }

    private var shutter: some View {
        Circle()
            .fill(isRecording ? Color.red : Color.accentColor)
            .frame(width: 72, height: 72)
            .overlay {
                Image(systemName: isRecording ? "stop.fill" : "video.fill")
                    .font(.title2)
                    .foregroundStyle(.white)
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
