import SwiftUI
import AVFoundation

#if os(iOS)
import UIKit

/// A photograph, opened, behaving the way a photograph on this platform behaves.
///
/// This is a `UIScrollView` and not a pair of SwiftUI gestures, and the reason is not that the
/// gestures were hard to write — the previous version of this screen wrote them, and they worked in
/// the sense that a pinch made the picture bigger. It is that "like the Photos app" is a list of
/// about a dozen behaviours nobody ever names until one of them is missing:
///
/// - The zoom follows the *centroid of the fingers*, so the part of the picture you pinched stays
///   under them instead of the middle of the photograph rushing towards you.
/// - The pan has momentum, and stops dead at the edges of the picture rather than letting it drift
///   off into the black.
/// - Pushed past an edge, it rubber-bands and comes back.
/// - A double tap zooms to *where it was tapped* — not to the centre — and a second one goes back.
/// - Pinched smaller than the screen, it springs back to fit rather than sitting there shrunken.
/// - Let go mid-pinch, it settles on a round number.
///
/// Every one of those is `UIScrollView`, for free, correct, and the same as every other photograph
/// on the phone. Written by hand they are a dozen pieces of arithmetic, each of which can be
/// slightly wrong in a way nobody can name either — which is exactly how the version this replaces
/// ended up with a photograph that could be zoomed into a corner and not brought back.
///
/// What is *not* free is the drag that closes the viewer, because at 1× a scroll view has nothing
/// to scroll and swallows the gesture anyway. That is the one recogniser added here, and it is
/// allowed to begin only when the picture is unzoomed and the finger is going down the screen — so
/// a two-fingered pinch is never mistaken for a flick away, and a pan across a magnified photograph
/// is never mistaken for one either.
struct ZoomableImage: UIViewRepresentable {
    let image: UIImage

    /// As far in as the picture is worth going, and how far a double tap takes it.
    let maximumZoom: CGFloat
    let doubleTapZoom: CGFloat

    /// How far in from the screen's edges the picture sits at 1×. Zoomed, it is not held to it.
    let inset: CGFloat

    /// How far the flick-to-close has come, 0 to 1. Drives the backdrop and the chrome, which fade
    /// as the photograph leaves rather than after it has gone.
    let onDismissProgress: (CGFloat) -> Void

    /// Far enough. The picture goes the rest of the way by itself.
    let onDismiss: () -> Void

    /// A single tap, which in a photo viewer means "show me the picture and nothing else".
    let onSingleTap: () -> Void

    /// Whether the picture is currently magnified. The chrome gets out of the way while it is —
    /// somebody who has zoomed in is looking at the photograph, not at the buttons.
    let onZoomChanged: (Bool) -> Void

    func makeUIView(context: Context) -> UIScrollView {
        let scroll = LayoutReportingScrollView()
        let coordinator = context.coordinator

        scroll.delegate = coordinator
        scroll.backgroundColor = .clear
        scroll.showsVerticalScrollIndicator = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = maximumZoom
        // The safe area belongs to the screen, not to the picture: a photograph inset by the notch
        // is a photograph with a black band across the top of it.
        scroll.contentInsetAdjustmentBehavior = .never
        // The rate a photo library flicks at. The default is a scroll view for reading lists with,
        // and on a picture it feels like the photograph is being shoved rather than thrown.
        scroll.decelerationRate = .fast

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        scroll.addSubview(imageView)

        coordinator.scrollView = scroll
        coordinator.imageView = imageView
        scroll.onLayout = { [weak coordinator] in coordinator?.layoutImage() }

        let double = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.doubleTapped))
        double.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(double)

        // The single tap waits for the double one to fail, which is what stops a zoom from also
        // taking the chrome away on its way in.
        let single = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.singleTapped))
        single.require(toFail: double)
        scroll.addGestureRecognizer(single)

        let dismissPan = UIPanGestureRecognizer(target: coordinator, action: #selector(Coordinator.dismissPanned))
        dismissPan.delegate = coordinator
        scroll.addGestureRecognizer(dismissPan)
        coordinator.dismissPan = dismissPan

        return scroll
    }

    func updateUIView(_ scroll: UIScrollView, context: Context) {
        // The closures are rebuilt every time the owning view's body runs, and a coordinator holding
        // the first set would be reporting a drag to a view that no longer exists.
        context.coordinator.parent = self

        if context.coordinator.imageView?.image !== image {
            context.coordinator.imageView?.image = image
            context.coordinator.layoutImage(force: true)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    @MainActor
    final class Coordinator: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate {
        var parent: ZoomableImage
        weak var scrollView: UIScrollView?
        weak var imageView: UIImageView?
        weak var dismissPan: UIPanGestureRecognizer?

        /// The bounds the picture was last laid out for. A photograph is fitted to the screen once
        /// per screen *size*, not once per layout pass — recomputing it on every pass would undo
        /// the user's zoom each time the scroll view moved.
        private var laidOutFor: CGSize = .zero

        /// How far down the flick has come, in points.
        private var dragged: CGFloat = 0

        init(parent: ZoomableImage) {
            self.parent = parent
        }

        // MARK: Layout

        func layoutImage(force: Bool = false) {
            guard let scroll = scrollView, let imageView, let image = imageView.image else { return }

            let bounds = scroll.bounds.size
            guard bounds.width > 0, bounds.height > 0 else { return }

            if force || bounds != laidOutFor {
                laidOutFor = bounds

                // The picture at 1× is the picture fitted to the screen, so every zoom scale after
                // that is a multiple of "as big as it goes without being cropped" — which is what
                // makes the minimum scale mean something and the rubber band stop in the right place.
                // A little short of the edges, so it floats over what is behind it.
                let fitted = AVMakeRect(aspectRatio: image.size,
                                        insideRect: CGRect(origin: .zero, size: bounds)
                                            .insetBy(dx: parent.inset, dy: parent.inset))
                scroll.zoomScale = 1
                // Bounds, not frame: the zooming view carries the scroll view's transform, and a
                // frame set through a transform is undefined.
                imageView.bounds = CGRect(origin: .zero, size: fitted.size)
                scroll.contentSize = fitted.size
                scroll.contentInset = .zero
            }

            centreImage()
        }

        /// Keeps the picture in the middle of the screen while it is smaller than the screen.
        ///
        /// A scroll view pins its content to the top left, so a photograph narrower than the window
        /// sits in the corner. This used to be cured with `contentInset`, recomputed on every step
        /// of a pinch — and a pinch keeps the point under the fingers still by moving the content
        /// offset against the insets *it started with*. Changing them under it is what made the
        /// zoom crooked: the photograph slid away from the fingers, and jumped as it grew past the
        /// screen's edge and the inset fell to zero. Now the picture's *centre* is moved instead,
        /// within content that is at least as big as the screen, and the insets are never touched.
        private func centreImage() {
            guard let scroll = scrollView, let imageView else { return }

            let content = scroll.contentSize
            imageView.center = CGPoint(x: max(content.width, scroll.bounds.width) / 2,
                                       y: max(content.height, scroll.bounds.height) / 2)
        }

        // MARK: Zooming

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            centreImage()
        }

        /// Said at the *start* of a pinch, not at its end. The gallery around this pages sideways,
        /// and until it hears that a zoom has begun its own pan is live — so a pinch that drifted
        /// sideways dragged the next photograph in while this one was growing.
        func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
            parent.onZoomChanged(true)
        }

        func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
            parent.onZoomChanged(scale > scrollView.minimumZoomScale + 0.01)
        }

        @objc func doubleTapped(_ recogniser: UITapGestureRecognizer) {
            guard let scroll = scrollView, let imageView else { return }

            if scroll.zoomScale > scroll.minimumZoomScale + 0.01 {
                scroll.setZoomScale(scroll.minimumZoomScale, animated: true)
                parent.onZoomChanged(false)
                return
            }

            // Zoom to where the finger was, not to the middle. `zoom(to:)` takes a rectangle in the
            // *image's* coordinates and fits it to the screen, so the rectangle is the screen
            // divided by the scale, centred on the tap.
            let scale = min(parent.doubleTapZoom, scroll.maximumZoomScale)
            let point = recogniser.location(in: imageView)
            let size = CGSize(width: scroll.bounds.width / scale, height: scroll.bounds.height / scale)
            let target = CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                                width: size.width, height: size.height)
            scroll.zoom(to: target, animated: true)
            parent.onZoomChanged(true)
        }

        @objc func singleTapped() {
            parent.onSingleTap()
        }

        // MARK: Closing

        /// How far down the picture has to be thrown, and how fast is fast enough to count without
        /// having gone that far — the two halves of every dismissal gesture on this platform.
        private static let dismissDistance: CGFloat = 120
        private static let dismissVelocity: CGFloat = 900

        /// How small the picture gets on its way out, at the point it leaves. Enough to read as the
        /// photograph falling back into the conversation, and not so much that it looks thrown away.
        private static let shrink: CGFloat = 0.3

        @objc func dismissPanned(_ recogniser: UIPanGestureRecognizer) {
            guard let scroll = scrollView, let imageView else { return }

            let translation = recogniser.translation(in: scroll)

            switch recogniser.state {
            case .changed:
                dragged = translation.y
                // Downwards only. Dragging a photograph *up* off the screen is not a gesture
                // anything else on this platform honours.
                let travel = max(0, dragged)
                let progress = min(1, travel / (scroll.bounds.height * 0.5))
                imageView.transform = CGAffineTransform(translationX: translation.x, y: travel)
                    .scaledBy(x: 1 - progress * Self.shrink, y: 1 - progress * Self.shrink)
                parent.onDismissProgress(progress)

            case .ended, .cancelled, .failed:
                let velocity = recogniser.velocity(in: scroll).y
                let isAway = dragged > Self.dismissDistance || velocity > Self.dismissVelocity

                dragged = 0

                guard isAway, recogniser.state == .ended else {
                    // Short of it: back where it was, and the conversation behind it goes back under
                    // the black. A spring rather than a fade, because the picture is a thing being
                    // put down rather than a thing appearing.
                    UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.85,
                                   initialSpringVelocity: 0) {
                        imageView.transform = .identity
                    }
                    parent.onDismissProgress(0)
                    return
                }

                parent.onDismiss()

            default:
                break
            }
        }

        /// The one question that keeps the flick and the scroll view out of each other's way.
        ///
        /// It begins only on an unzoomed picture — magnified, a downward drag is a pan across the
        /// photograph and nothing else — and only when the finger is actually going *down*: a
        /// sideways drag at 1× belongs to whatever is paging between photographs above this.
        func gestureRecognizerShouldBegin(_ recogniser: UIGestureRecognizer) -> Bool {
            guard recogniser === dismissPan,
                  let pan = recogniser as? UIPanGestureRecognizer,
                  let scroll = scrollView else { return true }

            guard scroll.zoomScale <= scroll.minimumZoomScale + 0.01 else { return false }
            // One finger. Two is a pinch that has not been recognised as one yet.
            guard pan.numberOfTouches <= 1 else { return false }

            let velocity = pan.velocity(in: scroll)
            return velocity.y > 0 && abs(velocity.y) > abs(velocity.x)
        }

        /// The scroll view's own pan is always there, even at 1× where it has nothing to do. Letting
        /// both run rather than making one wait means the picture answers the very first millimetre
        /// of the flick instead of a tenth of a second into it.
        func gestureRecognizer(_ recogniser: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}

/// A scroll view that says when it has laid itself out.
///
/// The picture has to be re-fitted whenever the window changes size — a rotation, a Split View, a
/// Mac window dragged wider — and a `UIViewRepresentable` is told about none of those. `layoutSubviews`
/// is where the platform already knows.
private final class LayoutReportingScrollView: UIScrollView {
    var onLayout: (() -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }
}
#endif
