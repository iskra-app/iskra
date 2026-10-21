import SwiftUI

/// The spark on an empty place — the detail column with no chat open — blinking: every three
/// seconds its eyes close for a moment. The same mark and the same blink as the web client's.
///
/// A blink is a change of picture, not a movement, but it is still something happening on its own
/// on a screen nobody touched, so with Reduce Motion on the eyes simply stay open.
public struct BlinkingSpark: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shut = false

    public init() {}

    public var body: some View {
        SparkGlyph(eyes: !shut)
            .fill(.quaternary, style: FillStyle(eoFill: true))
            .frame(width: Theme.Size.watermark, height: Theme.Size.watermark)
            .accessibilityHidden(true)
            .task(id: reduceMotion) {
                shut = false
                guard !reduceMotion else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(for: Theme.Timing.blinkEvery)
                    guard !Task.isCancelled else { return }
                    shut = true
                    try? await Task.sleep(for: Theme.Timing.blinkShut)
                    shut = false
                }
            }
    }
}
