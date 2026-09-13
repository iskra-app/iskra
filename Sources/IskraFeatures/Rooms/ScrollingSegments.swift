#if os(iOS)
import SwiftUI
import UIKit

/// The system's segmented control, as wide as its own words, on a strip that can be pushed
/// sideways — which SwiftUI cannot express and UIKit can, for one reason worth writing down.
///
/// A `Picker(.segmented)` inside a horizontal `ScrollView` *looks* like it should work, and it does
/// not: the finger never reaches the scroll view. `UIScrollView.touchesShouldCancel(in:)` returns
/// false for any `UIControl` that is not a button, on the reasoning that a switch or a slider under
/// a finger is being *used* rather than dragged past. A segmented control is exactly such a
/// control, so a drag across it is tracked by the control and the strip stands still. Nothing in
/// the SwiftUI version of that arrangement is reachable to argue with — the scroll view has no
/// delegate to hand and no subclass to name.
///
/// So the scroll view is ours and the control inside it is the system's, which is the split that
/// matters: every pixel the reader sees — the fill sliding between segments, the tint, the
/// pressed state, the focus ring, VoiceOver's "tab, 1 of 6", and whatever Apple does to this
/// control in iOS 27 — is drawn by UIKit. What we supply is the eighty lines around it that let it
/// be wider than the phone.
///
/// Three constraints do the whole job:
///
/// - the control's width is *at least* the strip's, so three tabs in a personal chat stretch to
///   fill the row and sit there like an ordinary segmented control, with nothing to scroll;
/// - `apportionsSegmentWidthsByContent` lets each segment take the width of its own word, so
///   «Кружки» does not get the same slice as «Фото и видео» and nothing is truncated to «Виде…»;
/// - the content guide is pinned to the control, so the scrollable width *is* the control's width,
///   and the strip scrolls exactly as far as there are words to see.
struct ScrollingSegments: View {
    let titles: [String]
    @Binding var selection: Int

    /// What the strip is called before its segments are read out. See `Strings.Room.Tabs.label`.
    let label: String

    var body: some View {
        Representable(titles: titles, selection: $selection, label: label)
            // The control has one honest height and no opinion about width; without this SwiftUI
            // hands the row whatever a `UIScrollView` claims to want, which is nothing at all.
            .frame(height: Representable.height)
    }

    private struct Representable: UIViewRepresentable {
        let titles: [String]
        @Binding var selection: Int
        let label: String

        /// The control's own height, asked of a throwaway control rather than written down as a
        /// number: it is 32 today and it was not always, and it grows with Dynamic Type.
        static var height: CGFloat {
            let probe = UISegmentedControl(items: ["Ag"])
            return probe.intrinsicContentSize.height
        }

        func makeUIView(context: Context) -> UIScrollView {
            let control = UISegmentedControl(items: titles)
            control.selectedSegmentIndex = selection
            // Each segment as wide as its own word. Off — the default — every segment is as wide as
            // the widest, which wastes a third of the strip on padding around «Файлы».
            control.apportionsSegmentWidthsByContent = true
            control.translatesAutoresizingMaskIntoConstraints = false
            control.addTarget(context.coordinator,
                              action: #selector(Coordinator.changed(_:)),
                              for: .valueChanged)

            let strip = Strip()
            strip.showsHorizontalScrollIndicator = false
            strip.showsVerticalScrollIndicator = false
            // Only when there is something off the edge. A strip that rubber-bands with three tabs
            // in it reads as a row that is hiding something.
            strip.alwaysBounceHorizontal = false
            strip.delaysContentTouches = false
            strip.accessibilityLabel = label
            strip.addSubview(control)

            let content = strip.contentLayoutGuide
            let frame = strip.frameLayoutGuide

            // At least as wide as the strip, and as wide as its words when they are wider. The
            // `defaultLow` priority is what lets the second win: the control would rather be its
            // intrinsic width, and this constraint only stops it being narrower than the row.
            let fill = control.widthAnchor.constraint(greaterThanOrEqualTo: frame.widthAnchor)
            fill.priority = .required

            NSLayoutConstraint.activate([
                control.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                control.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                control.topAnchor.constraint(equalTo: content.topAnchor),
                control.bottomAnchor.constraint(equalTo: content.bottomAnchor),
                control.heightAnchor.constraint(equalTo: frame.heightAnchor),
                fill
            ])

            context.coordinator.control = control
            return strip
        }

        func updateUIView(_ strip: UIScrollView, context: Context) {
            context.coordinator.selection = $selection

            guard let control = context.coordinator.control else { return }

            // The tabs themselves change as a room gains its first file or loses its last photo,
            // and rebuilding the control is cheaper than reasoning about which segment moved.
            if control.numberOfSegments != titles.count
                || (0..<control.numberOfSegments).contains(where: { control.titleForSegment(at: $0) != titles[$0] }) {
                control.removeAllSegments()
                for (index, title) in titles.enumerated() {
                    control.insertSegment(withTitle: title, at: index, animated: false)
                }
            }

            if control.selectedSegmentIndex != selection {
                control.selectedSegmentIndex = selection
            }
        }

        func makeCoordinator() -> Coordinator {
            Coordinator(selection: $selection)
        }

        @MainActor
        final class Coordinator {
            var selection: Binding<Int>
            weak var control: UISegmentedControl?

            init(selection: Binding<Int>) {
                self.selection = selection
            }

            @objc func changed(_ sender: UISegmentedControl) {
                selection.wrappedValue = sender.selectedSegmentIndex
            }
        }
    }

    /// The scroll view that lets go.
    ///
    /// This override is the entire reason there is UIKit on this screen: the base class refuses to
    /// take a drag away from a `UIControl`, which is right for a slider and wrong for a row of tabs
    /// that has to be pushed sideways. Returning true means a finger that *moves* becomes a scroll
    /// and the control forgets it; a finger that does not move is still a tap on a segment, because
    /// cancelling only happens once the touch has travelled.
    private final class Strip: UIScrollView {
        override func touchesShouldCancel(in view: UIView) -> Bool { true }
    }
}
#endif
