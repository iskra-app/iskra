import SwiftUI
import IskraCore
import IskraDesign

/// An attachment of ours on its way up, drawn the way Telegram draws it: a ring over the picture
/// that fills as the bytes go, with a cross in the middle that takes the message back.
///
/// The clock beside the bubble says the same thing in principle, and in practice it says nothing
/// at all for a minute-long video on a slow network — it is the same clock for a message that is
/// one second from landing and for one that is stuck, and the reader cannot tell which. A ring that
/// moves is the difference. The cross is there because the ring is also where somebody looks when
/// they have changed their mind: it is `discard`, the same call the red badge offers, and it reaches
/// nobody because nothing has reached anybody yet.
struct UploadProgressOverlay: ViewModifier {
    let message: Message
    let onCancel: () -> Void

    func body(content: Content) -> some View {
        content
            .overlay {
                if let progress = message.uploadProgress, Self.isPicture(message.kind) {
                    UploadRing(progress: progress, onCancel: onCancel)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
            .overlay(alignment: .bottom) {
                // A file is a line of text with an icon, not a picture, and a ring the size of the
                // bubble would sit on the name. A thin bar along its foot says the same thing.
                if let progress = message.uploadProgress, !Self.isPicture(message.kind) {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .padding(.horizontal, Theme.Spacing.normal)
                        .padding(.bottom, Theme.Spacing.tight)
                        .transition(.opacity)
                }
            }
            // Scoped to the one value, and to this overlay: the ring is the only thing here that
            // moves, and a scope wider than this would animate whatever else changed in the pass.
            .animation(.smooth(duration: Theme.Timing.chrome), value: message.uploadProgress == nil)
    }

    private static func isPicture(_ kind: MessageKind) -> Bool {
        switch kind {
        case .image, .video, .videoNote: true
        default: false
        }
    }
}

/// The ring itself: a dark disc, the arc of what has gone, and the cross.
struct UploadRing: View {
    let progress: Double
    let onCancel: () -> Void

    var body: some View {
        Button(action: onCancel) {
            ZStack {
                Circle()
                    .fill(.black.opacity(Theme.Backdrop.plate))

                Circle()
                    .trim(from: 0, to: max(0.02, progress))
                    .stroke(.white, style: StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(Self.inset)
                    // The arc runs up smoothly between reports rather than in steps — the SDK reports
                    // in chunks, and a ring that jumps reads as a ring that stalls.
                    .animation(.linear(duration: Theme.Timing.chrome), value: progress)

                Image(systemName: "xmark")
                    .font(.system(size: Self.diameter * 0.32, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: Self.diameter, height: Self.diameter)
            .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(Strings.Message.Delivery.cancelUpload))
        .accessibilityValue(Text(progress, format: .percent.precision(.fractionLength(0))))
    }

    private static let diameter = Theme.Size.uploadRing
    /// The arc is a hairline drawn on a picture, not a spacing — thin enough to read as progress
    /// rather than as a second circle.
    private static let lineWidth: CGFloat = 2.5
    private static let inset = Theme.Spacing.tight
}

extension View {
    /// The upload ring, for a message of ours whose attachment is still going up. See
    /// `UploadProgressOverlay`.
    func uploadProgress(of message: Message, onCancel: @escaping () -> Void) -> some View {
        modifier(UploadProgressOverlay(message: message, onCancel: onCancel))
    }
}
