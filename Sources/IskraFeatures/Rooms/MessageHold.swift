import SwiftUI

#if os(iOS)
import UIKit

/// The hold that lifts a message into its menu — done in UIKit, because SwiftUI's own long press
/// stops the conversation scrolling and there is no way to ask it not to.
///
/// That sentence was arrived at by measurement, after three attempts at fixing the scroll by
/// rearranging SwiftUI gestures. A throwaway harness — a `ScrollView` of bubbles and the app's
/// gesture stack, driven by XCUITest on a simulator — was given one question: after a finger lands
/// on a bubble and pulls, how far has the list travelled? The answers, in points:
///
///     bare list                            250
///     swipe-to-reply, any attachment       250
///     double tap, simultaneous or high     250
///     delaysContentTouches off             250
///     LongPressGesture, simultaneous         0
///     LongPressGesture, plain                0
///     LongPressGesture, high priority        0
///     LongPressGesture, maximumDistance 2    0
///     UILongPressGestureRecognizer         250
///
/// So it is not the priority, not the swipe, and not `ScrollTouches`: **a SwiftUI
/// `LongPressGesture` attached to content inside a `ScrollView` takes the touch and the scroll view
/// never gets it**, and no attachment modifier and no `maximumDistance` changes that. A UIKit
/// recogniser does not, because in UIKit the relationship between two recognisers is something you
/// can state: `shouldRecognizeSimultaneouslyWith` says yes, and the scroll view's pan is free.
///
/// **Where it is attached matters as much as what it is.** The obvious placement — a UIKit view
/// laid over the row — measured 250 for the scroll and then took every tap *underneath* it with it,
/// because a view on top of a message is the view a touch is delivered to and the message's own
/// gestures are attached below. The same harness said so: single taps fell from four to nought. So
/// this view blocks nothing at all — it is invisible to hit-testing — and hangs its recogniser on
/// the enclosing `UIScrollView`, which is an *ancestor* of every row and therefore sees every touch
/// the rows see, without standing in front of any of them.
///
/// One recogniser per message on a scroll view holding all of them means each has to ask whether a
/// touch was its own: hence the frame check, and hence `mine`. Without it the harness reported
/// thirty presses for one hold — every row in the list answering the same finger.
struct MessageHold: UIViewRepresentable {
    /// How long the finger has to stay. `Theme.Timing.menuLift`, handed in rather than read here,
    /// because this file is about touches and not about how long the app likes to wait.
    let duration: TimeInterval

    /// Whether a finger is down on this message right now — what the sinking bubble is drawn from.
    let onPressingChanged: (Bool) -> Void

    /// The hold happened: lift the message into the menu.
    let onHold: () -> Void

    /// After the hold, the same finger moving over the menu, in window coordinates — and coming up.
    /// What lets an item be chosen without lifting the finger first (`MessageMenuPresenter.slide`).
    var onSlide: ((CGPoint) -> Void)?
    var onRelease: (() -> Void)?

    func makeUIView(context: Context) -> UIView {
        let view = AttachingView()
        // Invisible to touches, and that is the entire point — see the note above about the
        // overlay that ate every tap beneath it.
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        view.coordinator = context.coordinator
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.onPressingChanged = onPressingChanged
        context.coordinator.onHold = onHold
        context.coordinator.onSlide = onSlide
        context.coordinator.onRelease = onRelease
        context.coordinator.duration = duration
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(duration: duration, onPressingChanged: onPressingChanged, onHold: onHold)
    }

    /// Recognisers live on the scroll view, not on this view, so they have to be taken off it again
    /// when the row scrolls out of the conversation — otherwise a long room accumulates one pair per
    /// message ever drawn.
    static func dismantleUIView(_ view: UIView, coordinator: Coordinator) {
        coordinator.detach()
    }

    /// A view whose only job is to notice where it has been put.
    ///
    /// `didMoveToWindow` rather than `makeUIView`: a representable's view has no superview at the
    /// moment it is made, so there is nothing to walk up from yet.
    final class AttachingView: UIView {
        var coordinator: Coordinator?

        override func didMoveToWindow() {
            super.didMoveToWindow()

            guard window != nil else {
                coordinator?.detach()
                return
            }
            coordinator?.attach(measuring: self)
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var duration: TimeInterval
        var onPressingChanged: (Bool) -> Void
        var onHold: () -> Void
        var onSlide: ((CGPoint) -> Void)?
        var onRelease: (() -> Void)?

        /// Whether this row's hold fired and its finger is still down — the stretch in which the
        /// finger is choosing from the menu rather than pressing a message.
        private var isSliding = false

        /// The row this speaks for, which is also the rectangle a touch has to be inside.
        private weak var mine: UIView?
        private weak var host: UIView?
        private var hold: UILongPressGestureRecognizer?
        private var touch: UILongPressGestureRecognizer?

        /// Where the finger came down, so that a finger that has set off scrolling can stop looking
        /// like a finger that is pressing.
        private var start: CGPoint?

        /// How far a finger may wander before it is scrolling rather than pressing. UIKit's own
        /// figure for a long press.
        private static let slop: CGFloat = 10

        init(duration: TimeInterval,
             onPressingChanged: @escaping (Bool) -> Void,
             onHold: @escaping () -> Void) {
            self.duration = duration
            self.onPressingChanged = onPressingChanged
            self.onHold = onHold
        }

        func attach(measuring view: UIView) {
            guard hold == nil else { return }
            mine = view

            // The enclosing scroll view — an ancestor of the row, so its recognisers see the row's
            // touches. Failing that (a message drawn outside a list at all), the highest ancestor
            // there is: the frame check below makes either safe.
            var walk: UIView? = view.superview
            var top: UIView? = view.superview
            while let candidate = walk {
                if candidate is UIScrollView { break }
                top = candidate
                walk = candidate.superview
            }
            guard let host = walk ?? top else { return }
            self.host = host

            let hold = UILongPressGestureRecognizer(target: self, action: #selector(held))
            hold.minimumPressDuration = duration
            hold.allowableMovement = Self.slop
            configure(hold)
            host.addGestureRecognizer(hold)
            self.hold = hold

            // A second recogniser, recognising at once, purely so the bubble can start sinking when
            // the finger lands rather than when the wait is already over — the animation is a
            // preview of the wait, and a preview that begins at the end of it says nothing.
            let touch = UILongPressGestureRecognizer(target: self, action: #selector(touched))
            touch.minimumPressDuration = 0
            configure(touch)
            host.addGestureRecognizer(touch)
            self.touch = touch
        }

        private func configure(_ recogniser: UILongPressGestureRecognizer) {
            // Nothing here consumes a touch: every other gesture in the app — the scroll view's own
            // pan first among them — goes on seeing everything.
            recogniser.cancelsTouchesInView = false
            recogniser.delaysTouchesBegan = false
            recogniser.delaysTouchesEnded = false
            recogniser.delegate = self
        }

        func detach() {
            if let hold { host?.removeGestureRecognizer(hold) }
            if let touch { host?.removeGestureRecognizer(touch) }
            hold = nil
            touch = nil
            host = nil
            onPressingChanged(false)
        }

        /// Whether this touch belongs to this message. One recogniser per row on a view that holds
        /// all of them, so every one of them is asked about every touch.
        private func isMine(_ recogniser: UIGestureRecognizer) -> Bool {
            guard let mine, mine.window != nil else { return false }
            let point = recogniser.location(in: mine)
            return mine.bounds.contains(point)
        }

        @objc private func held(_ recogniser: UILongPressGestureRecognizer) {
            switch recogniser.state {
            case .began:
                guard isMine(recogniser) else { return }
                isSliding = onSlide != nil
                // The conversation stops following the finger: from here on it is choosing from
                // the menu, and a list scrolling under it would carry the gap the message left
                // away from where the message will land. Switching the pan off and on cancels
                // the touch it has; the next touch is the list's again.
                if isSliding, let scroll = host as? UIScrollView {
                    scroll.panGestureRecognizer.isEnabled = false
                    scroll.panGestureRecognizer.isEnabled = true
                }
                onHold()

            case .changed:
                guard isSliding else { return }
                onSlide?(recogniser.location(in: nil))

            case .ended:
                guard isSliding else { return }
                isSliding = false
                onSlide?(recogniser.location(in: nil))
                onRelease?()

            default:
                isSliding = false
            }
        }

        @objc private func touched(_ recogniser: UILongPressGestureRecognizer) {
            switch recogniser.state {
            case .began:
                guard isMine(recogniser) else { return }
                start = recogniser.location(in: nil)
                onPressingChanged(true)

            case .changed:
                // A finger that has travelled is scrolling, and a bubble that stayed sunk under it
                // would be the app claiming to be waiting for something it has already given up on.
                guard let start else { return }
                let now = recogniser.location(in: nil)
                if hypot(now.x - start.x, now.y - start.y) > Self.slop {
                    self.start = nil
                    onPressingChanged(false)
                }

            default:
                start = nil
                onPressingChanged(false)
            }
        }

        /// Yes, to everything. This is the answer SwiftUI's long press has no way of giving, and the
        /// whole reason the conversation scrolls again.
        nonisolated func gestureRecognizer(_ recogniser: UIGestureRecognizer,
                                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}
#endif
